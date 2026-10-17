require "rails_helper"

# Pilot 10 M4-2 — punch corrections and payroll-period finalization coordinate on
# the period row (and two approvals on the request row), proven with TWO
# database connections: a second connection is the only thing a row lock can
# block. Lock order: request → payroll period → payroll entry (M4-3) → attendance / payroll rows;
# Payroll::Approver (the only path to finalized / paid) locks the period first.
#
# Deterministic: the operation under test is paused at a known point by a
# blocking Queue handshake (no sleeps), and the other connection either probes
# with FOR UPDATE NOWAIT or runs the real finalizer under a short lock_timeout
# — both fail immediately/boundedly while the row is held and never succeed
# while it is held, so the outcome cannot depend on scheduling.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates
# every table afterwards.
RSpec.describe "Punch correction ↔ payroll period locking (two connections)" do
  self.use_transactional_tests = false

  around { |ex| travel_to(Time.zone.local(2026, 7, 15, 12, 0, 0)) { ex.run } }

  def self.data_tables(conn) = conn.tables - %w[schema_migrations ar_internal_metadata]

  before do
    conn  = ActiveRecord::Base.connection
    dirty = self.class.data_tables(conn).select do |table|
      conn.select_value("SELECT EXISTS (SELECT 1 FROM #{conn.quote_table_name(table)})")
    end
    raise "test database not empty (#{dirty.first(5).join(', ')}…): refusing to run a truncating spec" if dirty.any?
  end

  after do
    conn = ActiveRecord::Base.connection
    conn.truncate_tables(*self.class.data_tables(conn))
  end

  let(:business) { create(:business, working_days_per_month: 22) }
  let(:tz)       { ActiveSupport::TimeZone[business.timezone] }
  let(:branch)   { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:reviewer) { create(:user, :owner, business: business) }
  let(:other_reviewer) { create(:user, business: business) }
  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let(:assignment) do
    create(:shift_assignment, user: employee, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22, status: "under_review")
  end
  let(:day) { Date.new(2026, 6, 8) }
  let(:attendance) do
    create(:attendance_record, user: employee, branch: branch, shift_assignment: assignment, date: day, work_date: day,
                               check_in_at: at(9, 40), check_out_at: at(15, 0), check_in_source: "device",
                               check_out_source: "device", status: "late").tap do |record|
      Attendance::RecordRecomputer.recompute!(record)
      record.save!
    end
  end
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee, base_salary: 8_800, net_salary: 8_500, needs_review: false)
  end

  before do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0, effective_from: Date.new(2026, 1, 1))
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 25)
    create(:penalty_rule, shift: shift, rule_type: "early_leave", threshold_minutes: 30,
                          deduction_type: "percentage_of_daily", deduction_value: 50)
    create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved",
                               source_type: "AttendanceRecord", source_id: attendance.id, original_minutes: 40)
    entry.recalculate_totals!
  end

  def at(hour, minute = 0, date: day) = tz.local(date.year, date.month, date.day, hour, minute)

  def correction
    build(:employee_request, :punch_correction, :pending, user: employee, requested_for_date: day,
                                                          correction_type: "wrong_check_in_time", proposed_time: "09:00",
                                                          proposed_date: day).tap { |req| req.save!(validate: false) }
  end

  def approve(req, by: reviewer)
    Requests::Approver.approve(request: req, reviewed_by: by, confirm_out_of_window: true)
  end

  def cancel(req) = Requests::Canceller.cancel(request: req, cancelled_by: reviewer, reason: "lock spec")
  def audits(req) = AuditLog.where(auditable: req).order(:id).pluck(:action)
  def late_line   = PayrollLineItem.find_by(payroll_entry_id: entry.id, item_type: "late_penalty")
  def period_now  = PayrollPeriod.find(period.id)

  # Pauses the next call of klass.method (on whichever thread) until released.
  def pause_inside(klass, method)
    reached = Queue.new
    release = Queue.new
    allow(klass).to receive(method).and_wrap_original do |original, *args, **kwargs, &block|
      reached << true
      release.pop
      original.call(*args, **kwargs, &block)
    end
    @releases = (@releases || []) << release
    [ reached, release ]
  end

  # Runs the block on its own thread and database connection.
  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { |t| t.report_on_exception = false }
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }
  def result_of(thread) = thread.join(10)&.value || raise("operation did not finish")

  def finalize_with_lock_timeout
    conn = ActiveRecord::Base.connection
    conn.execute("SET lock_timeout = '250ms'")
    Payroll::Approver.advance(period: period_now, by: reviewer)
  ensure
    conn.execute("RESET lock_timeout")
  end

  def expect_period_row_held
    expect { PayrollPeriod.transaction { PayrollPeriod.lock("FOR UPDATE NOWAIT").find(period.id) } }
      .to raise_error(ActiveRecord::LockWaitTimeout)
  end

  # M4-3: the existing entry is locked after the period, before it is recalculated.
  def expect_entry_row_held
    expect { PayrollEntry.transaction { PayrollEntry.lock("FOR UPDATE NOWAIT").find(entry.id) } }
      .to raise_error(ActiveRecord::LockWaitTimeout)
  end

  after { (@releases || []).each { |release| 2.times { release << true } } } # never leave a thread blocked

  describe "approval" do
    it "holds the period row from its lock check to its commit: finalization cannot run in between" do
      req = correction
      reached, release = pause_inside(Payroll::EntryRecalculator, :call) # after the period + entry locks, before the payroll write
      approval = on_other_connection { approve(req) }
      wait_for(reached)

      expect_period_row_held
      expect_entry_row_held
      blocked = finalize_with_lock_timeout
      expect(blocked).not_to be_success
      expect(blocked.error).to match(/lock timeout/)
      expect(period_now.status).to eq("under_review")

      release << true
      expect(result_of(approval)).to be_success
      expect(attendance.reload.late_minutes).to eq(0)
      expect(late_line).to be_nil # payroll followed attendance in the still-open period

      expect(Payroll::Approver.advance(period: period_now, by: reviewer)).to be_success
      expect(period_now.status).to eq("finalized")
    end

    it "a finalization committed before the approval reaches the period lock is seen after the lock: refused, nothing written" do
      req = correction
      reached, release = pause_inside(Attendance::PunchCorrectionEffects, :correction_approved) # request locked, period not yet
      approval = on_other_connection { approve(req) }
      wait_for(reached)

      expect(Payroll::Approver.advance(period: period_now, by: reviewer)).to be_success # the period row is free
      release << true

      result = result_of(approval)
      expect(result.error).to eq(I18n.t("requests.errors.cannot_approve_finalized"))
      expect(req.reload).to have_attributes(status: "pending", approved_punch_at: nil, original_check_in_at: nil)
      expect(attendance.reload).to have_attributes(check_in_at: at(9, 40), late_minutes: 40)
      expect(late_line).to have_attributes(amount: -100.0, original_minutes: 40)
      expect(audits(req)).to be_empty
    end

    it "two approvals on two connections: the second waits for the request row, then is refused" do
      req   = correction
      stale = EmployeeRequest.find(req.id)
      reached, release = pause_inside(Payroll::EntryRecalculator, :call)
      first = on_other_connection { approve(req) }
      wait_for(reached)

      second = on_other_connection { approve(stale, by: other_reviewer) } # blocks on the request row (or arrives later)
      release << true

      expect(result_of(first)).to be_success
      expect(result_of(second).error).to eq("Request is already approved")
      expect(req.reload).to have_attributes(reviewed_by_id: reviewer.id, original_check_in_at: at(9, 40),
                                            original_check_in_source: "device")
      expect(audits(req)).to eq([ "approve" ])
    end
  end

  describe "cancellation" do
    let!(:approved) { correction.tap { |req| expect(approve(req)).to be_success } }

    it "holds the period row from its lock check to its commit: finalization cannot run in between" do
      reached, release = pause_inside(Payroll::EntryRecalculator, :call)
      cancellation = on_other_connection { cancel(approved) }
      wait_for(reached)

      expect_period_row_held
      expect_entry_row_held
      blocked = finalize_with_lock_timeout
      expect(blocked.error).to match(/lock timeout/)
      expect(period_now.status).to eq("under_review")

      release << true
      expect(result_of(cancellation)).to be_success
      expect(attendance.reload.late_minutes).to eq(40)
      expect(late_line).to have_attributes(amount: -100.0, original_minutes: 40) # recreated in the still-open period

      expect(Payroll::Approver.advance(period: period_now, by: reviewer)).to be_success
    end

    it "a finalization committed before the cancellation reaches the period lock is seen after the lock: refused, nothing written" do
      reached, release = pause_inside(Attendance::PunchCorrectionEffects, :correction_cancelled)
      cancellation = on_other_connection { cancel(approved) }
      wait_for(reached)

      expect(Payroll::Approver.advance(period: period_now, by: reviewer)).to be_success
      release << true

      expect(result_of(cancellation).error).to eq(I18n.t("requests.errors.cannot_cancel_finalized"))
      expect(approved.reload.status).to eq("approved")
      expect(attendance.reload.late_minutes).to eq(0)
      expect(late_line).to be_nil
      expect(audits(approved)).to eq([ "approve" ])
    end
  end

  it "Payroll::Approver applies a transition only to the locked status the caller saw: a stale second finalization is refused" do
    stale = period_now
    expect(Payroll::Approver.advance(period: period_now, by: reviewer)).to be_success # under_review → finalized

    second = Payroll::Approver.advance(period: stale, by: reviewer) # its copy still says under_review
    expect(second.error).to eq("No transition available from 'finalized'")
    expect(period_now.status).to eq("finalized")                    # not re-finalized, not paid
    expect(PayrollAuditLog.where(payroll_period_id: period.id).pluck(:to_status)).to eq(%w[finalized])
  end
end
