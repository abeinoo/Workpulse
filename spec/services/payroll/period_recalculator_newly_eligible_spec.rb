require "rails_helper"

# Payroll::PeriodRecalculator — employees who became eligible after the period
# was calculated. The reported case (October 2026): Omar had attendance and an
# assigned shift but no salary profile when payroll was generated, so he got no
# entry; a profile effective Oct 25 was entered later, and Recalculate Payroll
# must now add him — paying only the days from Oct 25.
#
#   Omar — daily 300 effective Oct 25, at East (manager, no review slot yet).
#     Attendance: Oct 3 (late 60), Oct 10 (overtime 60) — before the profile,
#     unpaid, no items; Oct 25, Oct 26 (late 60), Oct 27 — paid:
#     base 3 × 300 = 900; late penalty on Oct 26 = 50% × 300 = 150.
#   Ahmed — daily 400 since January at North (signed off), unchanged.
RSpec.describe Payroll::PeriodRecalculator do
  around { |ex| travel_to(Time.zone.local(2026, 11, 10, 12, 0, 0)) { ex.run } }

  let(:business) do
    create(:business, working_days_per_month: 26, timezone: "UTC", overtime_grace_minutes: 30)
  end
  let(:north) { create(:branch, business: business, name: "North") }
  let(:east)  { create(:branch, business: business, name: "East") }
  let(:north_manager) { create(:user, business: business) }
  let(:east_manager)  { create(:user, business: business) }
  let!(:actor) { create(:user, :accountant, business: business) }
  let(:ahmed) { create(:user, business: business, first_name: "Ahmed", last_name: "Abdallah") }
  let(:omar)  { create(:user, business: business, first_name: "Omar", last_name: "Nasser") }

  let(:shift) do
    create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"),
           end_time: Time.zone.parse("17:00"), overtime_rate_multiplier: 1.5)
  end
  let!(:ahmed_assignment) do
    create(:shift_assignment, user: ahmed, branch: north, shift: shift, effective_from: Date.new(2026, 1, 1))
  end
  let!(:omar_assignment) do
    create(:shift_assignment, user: omar, branch: east, shift: shift, effective_from: Date.new(2026, 9, 1))
  end
  let!(:late_rule) do
    create(:penalty_rule, shift: shift, rule_type: "late_arrival", threshold_minutes: 15,
                          deduction_type: "percentage_of_daily", deduction_value: 50)
  end

  let(:october) { PayrollPeriod.find_by!(business: business, period_year: 2026, period_month: 10) }

  def oct(day) = Date.new(2026, 10, day)

  def work(user, assignment, date, late: 0, overtime: 0)
    create(:attendance_record, user: user, branch: assignment.branch, shift_assignment: assignment,
           date: date, work_date: date,
           check_in_at:  Time.zone.local(date.year, date.month, date.day, 9, 0) + late.minutes,
           check_out_at: Time.zone.local(date.year, date.month, date.day, 17, 0) + overtime.minutes,
           worked_minutes: 480 - late + overtime, late_minutes: late, early_leave_minutes: 0,
           status: late.positive? ? "late" : "present")
  end

  before do
    north.update_column(:branch_manager_id, north_manager.id)
    east.update_column(:branch_manager_id, east_manager.id)
    create(:salary_profile, :daily, user: ahmed, base_amount: 400, effective_from: Date.new(2026, 1, 1))
    [ 1, 2, 5, 6 ].each { |d| work(ahmed, ahmed_assignment, oct(d)) }
    work(omar, omar_assignment, oct(3), late: 60)
    work(omar, omar_assignment, oct(10), overtime: 60)
    work(omar, omar_assignment, oct(25))
    work(omar, omar_assignment, oct(26), late: 60)
    work(omar, omar_assignment, oct(27))

    # Generation: Omar is eligible (active, attendance) but has no salary profile → no entry.
    Payroll::PeriodGenerator.call(business: business, year: 2026, month: 10, generated_by: actor)
    october.payroll_entries.update_all(needs_review: false)
    october.update!(status: "under_review")
    create(:payroll_period_branch_review, payroll_period: october, branch: north, reviewer: north_manager,
                                          status: "completed", completed_at: Time.zone.local(2026, 11, 3, 9, 0))
  end

  def service(user = actor) = described_class.new(period_id: october.id, actor: user)
  def preview = service.preview.preview
  def apply!(digest = preview.digest, reason: "Salary profile entered for Omar") = service.apply!(expected_digest: digest, reason: reason)
  def entry_of(user) = october.payroll_entries.find_by(user: user)
  def row_of(plan, user) = plan.rows.find { |r| r.user_id == user.id }
  def enter_profile(effective_from: oct(25)) = create(:salary_profile, :daily, user: omar, base_amount: 300, effective_from: effective_from)

  def database_checksum
    conn = ActiveRecord::Base.connection
    (conn.tables - %w[schema_migrations ar_internal_metadata]).sort.to_h do |table|
      quoted = conn.quote_table_name(table)
      [ table, conn.select_value("SELECT md5(COALESCE(string_agg(t::text, '|' ORDER BY t::text), '')) FROM #{quoted} t") ]
    end
  end

  it "excluded the employee at generation: eligible, but no salary profile in force" do
    expect(entry_of(omar)).to be_nil
    expect(entry_of(ahmed)).to be_present
  end

  describe "a salary profile entered after generation" do
    before { enter_profile }

    it "previews the employee as added, with nothing before" do
      plan = preview
      row  = row_of(plan, omar)

      expect(row).to be_added
      expect(row).to be_changed
      expect(row.before).to be_nil
      expect(row.amount(:after, "base_salary")).to eq(BigDecimal("900"))
      expect(plan.added_rows.map(&:user_id)).to eq([ omar.id ])
      expect(plan).not_to be_blocked
      expect(plan).not_to be_nothing_to_change
      expect(row_of(plan, ahmed)).not_to be_changed
    end

    it "has zero persistent side effects in the preview" do
      before = database_checksum
      preview
      expect(database_checksum).to eq(before)
      expect(entry_of(omar)).to be_nil
    end

    it "gives the same digest on every preview (the new entry's id is not part of it)" do
      expect(preview.digest).to eq(preview.digest)
    end

    it "adds exactly one entry, paying only the days from the profile's effective date" do
      expect { expect(apply!).to be_ok }.to change { october.payroll_entries.count }.by(1)

      entry = entry_of(omar)
      expect(entry.base_salary).to eq(BigDecimal("900"))
      expect(entry.salary_type).to eq("daily")
      expect(entry.total_overtime).to eq(0) # the Oct 10 overtime was before the profile

      dated = entry.payroll_line_items.where(source_type: "AttendanceRecord")
      expect(AttendanceRecord.where(id: dated.map(&:source_id)).pluck(:work_date)).to all(be >= oct(25))
      late = entry.payroll_line_items.where(item_type: "late_penalty").sole
      expect(late.amount).to eq(BigDecimal("-150"))
      expect(AttendanceRecord.find(late.source_id).work_date).to eq(oct(26))
      expect(entry.net_salary).to eq(BigDecimal("750"))
    end

    it "flags the added entry for re-review, which blocks finalization" do
      apply!
      expect(entry_of(omar)).to have_attributes(needs_review: true, recalculation_review_required: true)
      expect(entry_of(ahmed)).to have_attributes(needs_review: false, recalculation_review_required: false)
    end

    it "is idempotent: nothing left to change, no duplicate, and a reused digest is refused" do
      digest = preview.digest
      expect(apply!(digest)).to be_ok

      second = preview
      expect(second.added_rows).to be_empty
      expect(second).to be_nothing_to_change
      expect(row_of(second, omar)).not_to be_changed

      expect { service.apply!(expected_digest: digest, reason: "again") }
        .not_to change { october.payroll_entries.count }
      expect(october.payroll_entries.where(user: omar).count).to eq(1)
    end

    it "records the added employee in the pre-recalculation snapshot, as not in payroll before" do
      apply!
      snapshot = october.payroll_snapshots.where(trigger: "pre_recalculate").sole
      expect(snapshot.employee_count).to eq(1)
      expect(snapshot.employee_details).to include({ "user_id" => omar.id, "in_payroll" => false })
      expect(snapshot.employee_details.map { |d| d["user_id"] }).to contain_exactly(ahmed.id, omar.id)
    end

    it "records the added employee in the audit entry" do
      apply!
      log  = october.payroll_audit_logs.where(action_type: "recalculated").sole
      meta = log.metadata_hash

      expect(meta["added_employee_count"]).to eq(1)
      expect(meta["changed_employee_count"]).to eq(1)
      added = meta["entries"].sole
      expect(added).to include("user_id" => omar.id, "entry_id" => entry_of(omar).id, "added" => true, "before" => nil)
      expect(added["after"]["base_salary"]).to eq("900.0")
    end

    it "refuses when the data changes after the preview, and writes nothing" do
      digest = preview.digest
      work(omar, omar_assignment, oct(28))
      before = database_checksum

      result = apply!(digest)
      expect(result.error).to eq(I18n.t("payroll.period_recalculation.errors.preview_changed"))
      expect(database_checksum).to eq(before)
    end

    it "keeps the totals consistent with the entries" do
      plan = preview
      expect(plan.totals_after.base_salary - plan.totals_before.base_salary).to eq(BigDecimal("900"))
    end
  end

  describe "branch and central review" do
    before { enter_profile }

    it "opens a pending review slot for the added employee's branch, assigned to its manager" do
      plan = preview
      expect(plan.new_review_slots).to eq([ east ])
      expect(plan.branches.find { |b| b.branch_id == east.id }).to have_attributes(opens_slot: true, review_status: nil)

      apply!
      slot = october.payroll_period_branch_reviews.find_by!(branch: east)
      expect(slot).to have_attributes(status: "pending", reviewer_id: east_manager.id)
      expect(october.reload).to be_under_review
      meta = october.payroll_audit_logs.where(action_type: "recalculated").sole.metadata_hash
      expect(meta["review_slots_opened"]).to eq([ { "branch_id" => east.id, "branch_name" => "East" } ])
    end

    it "keeps the existing sign-off of another branch" do
      apply!
      expect(october.payroll_period_branch_reviews.find_by!(branch: north)).to be_completed
    end

    it "returns a branch-review-completed period to under review, audited" do
      october.update!(status: "branch_review_completed")
      plan = preview
      expect(plan).to be_reopens_period

      expect(apply!(plan.digest)).to be_ok
      expect(october.reload).to be_under_review
      log = october.payroll_audit_logs.where(action_type: "recalculated").sole
      expect(log).to have_attributes(from_status: "branch_review_completed", to_status: "under_review")
      expect(log.metadata_hash["period_reopened"]).to be(true)
    end

    it "opens no slot when the added employee's branch already has one" do
      omar_assignment.update_columns(branch_id: north.id)
      plan = preview
      expect(plan.new_review_slots).to be_empty
      expect(plan).not_to be_reopens_period

      apply!(plan.digest)
      expect(october.payroll_period_branch_reviews.count).to eq(1)
      expect(october.payroll_audit_logs.where(action_type: "recalculated").sole.metadata_hash["review_slots_opened"]).to eq([])
    end

    it "sends an added floating employee to the central review" do
      omar_assignment.update_columns(branch_id: nil, assignment_kind: "floating")
      plan = preview
      central = plan.branches.find { |b| b.branch_id.nil? }
      expect(central).to have_attributes(opens_slot: true)
      expect(plan.new_review_slots).to be_empty

      apply!(plan.digest)
      expect(october.payroll_period_branch_reviews.central.sole).to be_pending
      expect(october.payroll_audit_logs.where(action_type: "central_review_reopened").sole.metadata_hash)
        .to include("reason" => "floating_employees_added")
    end
  end

  # Payroll pays from the profile's effective date and never reads the hire
  # date: a profile dated before the hire date pays days before employment.
  # The preview must expose it (and the audit record what was shown).
  describe "salary start date vs hire date" do
    it "flags an added employee whose salary starts before the hire date — paid from the profile date" do
      omar.update_column(:hire_date, oct(20))
      create(:salary_profile, :monthly, user: omar, base_amount: 9_000, effective_from: oct(1))

      plan = preview
      row  = row_of(plan, omar)
      expect(row).to have_attributes(salary_starts_on: oct(1), hire_date: oct(20), first_attendance_on: oct(3))
      expect(row).to be_starts_before_hire
      expect(plan.salary_start_alerts).to eq([ row ])
      expect(row.amount(:after, "base_salary")).to be > 0

      apply!(plan.digest)
      meta = october.payroll_audit_logs.where(action_type: "recalculated").sole.metadata_hash
      expect(meta["salary_start_alerts"]).to eq([ { "user_id" => omar.id, "salary_starts_on" => "2026-10-01",
                                                    "hire_date" => "2026-10-20", "first_attendance_on" => "2026-10-03" } ])
    end

    it "flags an added employee with no hire date recorded" do
      enter_profile
      row = row_of(preview, omar)
      expect(row).to be_hire_date_missing
      expect(preview.salary_start_alerts.map(&:user_id)).to eq([ omar.id ])
    end

    it "does not flag an added employee whose salary starts on or after the hire date" do
      omar.update_column(:hire_date, oct(25))
      enter_profile
      expect(row_of(preview, omar)).not_to be_salary_start_alert
      expect(preview.salary_start_alerts).to be_empty
    end

    it "flags a changed existing employee paid from before their hire date" do
      ahmed.update_column(:hire_date, oct(2))
      create(:salary_profile, :daily, user: ahmed, base_amount: 450, effective_from: oct(1)) # raise → changed
      row = row_of(preview, ahmed)
      expect(row).to be_changed
      expect(row).to have_attributes(salary_starts_on: oct(1), hire_date: oct(2))
      expect(preview.salary_start_alerts.map(&:user_id)).to eq([ ahmed.id ])
    end

    it "never flags an unchanged employee" do
      ahmed.update_column(:hire_date, Date.new(2027, 1, 1))
      expect(row_of(preview, ahmed)).not_to be_changed
      expect(preview.salary_start_alerts).to be_empty
    end
  end

  describe "employees who must not be added" do
    it "never borrows a future profile: a profile effective after the period adds nobody" do
      enter_profile(effective_from: Date.new(2026, 11, 3))
      plan = preview
      expect(row_of(plan, omar)).to be_nil
      expect(plan).not_to be_blocked
      expect(plan).to be_nothing_to_change
    end

    it "skips an eligible employee with no salary profile at all, without blocking the run" do
      plan = preview
      expect(row_of(plan, omar)).to be_nil
      expect(plan).not_to be_blocked
    end

    it "adds nobody while an existing entry blocks the run" do
      enter_profile
      nobody = create(:user, business: business, first_name: "Zed", last_name: "Blocked")
      create(:payroll_entry, payroll_period: october, user: nobody, base_salary: 1_000, net_salary: 1_000)

      plan = preview
      expect(plan).to be_blocked
      expect(plan.added_rows).to be_empty
      expect(apply!(plan.digest).error).to eq(I18n.t("payroll.period_recalculation.errors.blocked"))
      expect(entry_of(omar)).to be_nil
    end

    %w[finalized paid].each do |status|
      it "never adds an employee to a #{status} period" do
        enter_profile
        october.update_column(:status, status)
        before = database_checksum

        expect(service.preview).not_to be_ok
        expect(service.apply!(expected_digest: "x", reason: "r")).not_to be_ok
        expect(database_checksum).to eq(before)
      end
    end
  end

  describe "the automatic recalculation paths stay limited to existing entries" do
    it "does not add the employee when the salary profile is entered (Salary::ProfileUpdater)" do
      result = Salary::ProfileUpdater.call(user: omar, actor: actor,
                                           params: { salary_type: "daily", base_amount: 300, effective_from: oct(25) })
      expect(result).to be_success
      expect(entry_of(omar)).to be_nil
    end

    it "does not add the employee when attendance changes (Payroll::DraftRegenerator)" do
      enter_profile
      Payroll::DraftRegenerator.call(business: business, months: [ [ 2026, 10 ] ], triggered_by: actor)
      expect(entry_of(omar)).to be_nil
    end
  end
end
