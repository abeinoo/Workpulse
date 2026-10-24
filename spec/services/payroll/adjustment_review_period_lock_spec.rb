require "rails_helper"

# Adjustment review (approve / reject / approve-all-pending) and payroll-period
# finalization coordinate on the payroll period row, proven with TWO database
# connections — a second connection is the only thing a row lock can block.
# Lock order is "period first" everywhere: Payroll::Approver locks the period
# before finalizing or paying; PayrollAdjustment#approve_by!/#reject_by! lock
# period → adjustment; Payroll::PendingItemsApprover locks period → line items →
# adjustments.
#
# Deterministic, as spec/services/requests/punch_correction_period_lock_spec.rb:
# the operation under test is paused at a known point by a Queue handshake (no
# sleeps) and the other connection probes with FOR UPDATE NOWAIT or runs under a
# short lock_timeout, so the outcome cannot depend on scheduling.
#
# Not transactional (the other connection must see committed rows): every
# example refuses to start unless the test database is empty and truncates
# every table afterwards.
RSpec.describe "Adjustment review ↔ payroll period locking (two connections)" do
  self.use_transactional_tests = false

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

  let(:business) { create(:business) }
  let(:creator)  { create(:user, :accountant, business: business) }
  let(:approver) { create(:user, :accountant, business: business) }
  let(:other)    { create(:user, :accountant, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:period)   { create(:payroll_period, business: business, status: "under_review") }
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, net_salary: 5_000.0, total_bonuses: 0.0, total_deductions: 0.0)
  end
  let(:adjustment) do
    create(:payroll_adjustment, :cash_incentive, payroll_period: period, business: business,
           user: employee, created_by: creator, amount: 300.0)
  end
  let!(:line_item) do
    create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive", amount: 300.0,
           source_type: "PayrollAdjustment", source_id: adjustment.id, review_status: "pending_review")
  end

  def period_now = PayrollPeriod.find(period.id)
  def adjustment_now = PayrollAdjustment.find(adjustment.id)

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

  def on_other_connection(&block)
    Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }.tap { |t| t.report_on_exception = false }
  end

  def wait_for(queue) = Timeout.timeout(10) { queue.pop }
  def result_of(thread) = thread.join(10)&.value || raise("operation did not finish")

  def with_lock_timeout
    conn = ActiveRecord::Base.connection
    conn.execute("SET lock_timeout = '250ms'")
    yield
  ensure
    conn.execute("RESET lock_timeout")
  end

  def expect_period_row_held
    expect { PayrollPeriod.transaction { PayrollPeriod.lock("FOR UPDATE NOWAIT").find(period.id) } }
      .to raise_error(ActiveRecord::LockWaitTimeout)
  end

  after { (@releases || []).each { |release| 2.times { release << true } } } # never leave a thread blocked

  it "an approval holds the period row until it commits: finalization cannot run in between" do
    # Paused after approve_by! (period + adjustment locked), before materialising.
    reached, release = pause_inside(Payroll::AdjustmentApplier, :call)
    approval = on_other_connection { Adjustments::BulkReview.approve(adjustments: [ adjustment_now ], reviewer: approver) }
    wait_for(reached)

    expect_period_row_held
    blocked = with_lock_timeout { Payroll::Approver.advance(period: period_now, by: approver) }
    expect(blocked).not_to be_success
    expect(blocked.error).to match(/lock timeout/)
    expect(period_now.status).to eq("under_review")

    release << true
    expect(result_of(approval).succeeded).to eq(1)
    expect(adjustment_now).to be_approved
    expect(line_item.reload).to be_approved
    expect(entry.reload.net_salary).to eq(5_300.0) # applied while the period was still open

    expect(Payroll::Approver.advance(period: period_now, by: approver)).to be_success
  end

  # With the pending-adjustment guard a finalization cannot even start while this
  # adjustment is pending, so "review during a finalization in progress" reduces
  # to the creation case below; what remains is that the refusal changes nothing
  # and leaves the adjustment reviewable.
  it "finalization refuses while the adjustment is pending; the adjustment stays reviewable" do
    expect(Payroll::Approver.advance(period: period_now, by: approver).error).to eq(pending_error(1))
    expect(period_now.status).to eq("under_review")

    adjustment_now.reject_by!(approver)
    expect(Payroll::Approver.advance(period: period_now, by: approver)).to be_success
    expect(entry.reload.net_salary).to eq(5_000.0)
  end

  it "approve-all-pending holds the period row until it commits" do
    # Paused at the per-item approval rule — after the period and line-item locks.
    reached, release = pause_inside(Payroll::AdjustmentApproval, :permitted?)
    run = on_other_connection { Payroll::PendingItemsApprover.call(period_id: period.id, reviewer: approver) }
    wait_for(reached)

    expect_period_row_held
    blocked = with_lock_timeout { Payroll::Approver.advance(period: period_now, by: approver) }
    expect(blocked.error).to match(/lock timeout/)

    release << true
    expect(result_of(run)).to be_ok
    expect(line_item.reload).to be_approved
    expect(adjustment_now).to be_approved
  end

  # ── Pending-adjustment guard (Payroll::Approver refuses while any is pending) ──

  def finalize_with_lock_timeout = with_lock_timeout { Payroll::Approver.advance(period: period_now, by: approver) }
  def pending_error(count) = I18n.t("payroll.errors.pending_adjustments_finalize", count: count)

  def new_pending_adjustment
    PayrollAdjustment.create!(payroll_period: period, business: business, user: employee, created_by: creator,
                              adjustment_type: "commission", amount: 50, reason: "Late commission",
                              period_month: period.period_month, period_year: period.period_year,
                              review_status: "pending_review")
  end

  it "finalization waits for an in-flight review, then counts what it committed" do
    reached, release = pause_inside(Payroll::AdjustmentApplier, :call)
    approval = on_other_connection { Adjustments::BulkReview.approve(adjustments: [ adjustment_now ], reviewer: approver) }
    wait_for(reached)

    expect(finalize_with_lock_timeout.error).to match(/lock timeout/) # not "1 pending": it never read stale state
    release << true
    expect(result_of(approval).succeeded).to eq(1)

    expect(Payroll::Approver.advance(period: period_now, by: approver)).to be_success
  end

  it "a pending adjustment being created holds the period row until it commits; finalization then refuses" do
    reached = Queue.new
    release = Queue.new
    @releases = [ release ]
    creation = on_other_connection do
      PayrollAdjustment.transaction do
        new_pending_adjustment
        reached << true
        release.pop
      end
      :created
    end
    wait_for(reached)

    expect(finalize_with_lock_timeout.error).to match(/lock timeout/)
    expect(period_now.status).to eq("under_review")

    release << true
    expect(result_of(creation)).to eq(:created)
    expect(Payroll::Approver.advance(period: period_now, by: approver).error).to eq(pending_error(2))
    expect(period_now.status).to eq("under_review")
  end

  it "a finalization in progress makes a pending creation wait, then refuses it" do
    adjustment.update_column(:review_status, "rejected") # nothing pending: finalization proceeds
    reached, release = pause_inside(Payroll::FinalizationEffects, :period_finalized)
    finalization = on_other_connection { Payroll::Approver.advance(period: period_now, by: approver) }
    wait_for(reached)

    expect { with_lock_timeout { new_pending_adjustment } }.to raise_error(ActiveRecord::LockWaitTimeout)

    release << true
    expect(result_of(finalization)).to be_success
    expect { new_pending_adjustment }.to raise_error(ActiveRecord::RecordInvalid)
    expect(PayrollAdjustment.pending.where(payroll_period_id: period.id)).to be_empty
  end

  it "an approved adjustment being edited back to pending holds the period row; finalization then refuses" do
    adjustment.update_column(:review_status, "approved")
    line_item.update_column(:review_status, "approved")
    entry.recalculate_totals!
    reached, release = pause_inside(PayrollAdjustmentEdit, :create!) # after the demotion, before commit
    edit = on_other_connection do
      Payroll::AdjustmentEditor.new(adjustment_id: adjustment.id, actor: approver, params: { amount: "400" }).call
    end
    wait_for(reached)

    expect(finalize_with_lock_timeout.error).to match(/lock timeout/)
    expect(period_now.status).to eq("under_review")

    release << true
    expect(result_of(edit)).to be_ok
    expect(adjustment_now).to be_pending_review
    expect(Payroll::Approver.advance(period: period_now, by: approver).error).to eq(pending_error(1))
    expect(entry.reload.net_salary).to eq(5_000.0) # demoted item no longer counts; entry still open
  end

  it "two concurrent reviews on two connections: the second waits, then is refused" do
    stale = adjustment_now
    reached, release = pause_inside(Payroll::AdjustmentApplier, :call)
    first = on_other_connection { Adjustments::BulkReview.approve(adjustments: [ adjustment_now ], reviewer: approver) }
    wait_for(reached)

    second = on_other_connection do
      stale.reject_by!(other)
      :rejected
    rescue PayrollAdjustment::ReviewTransitionError => e
      e
    end
    release << true

    expect(result_of(first).succeeded).to eq(1)
    expect(result_of(second)).to be_a(PayrollAdjustment::ReviewTransitionError)
    expect(adjustment_now).to have_attributes(review_status: "approved", approved_by_id: approver.id,
                                              rejected_by_id: nil)
  end
end
