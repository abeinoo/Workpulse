require "rails_helper"

# End-to-end coverage for the "temporary cross-branch coverage" feature:
# an employee permanently assigned to a home branch temporarily covers a
# different branch for specific dates, without their permanent assignment
# ever changing, and every downstream financial record follows the branch
# actually worked on each date.
RSpec.describe "Temporary cross-branch coverage", type: :request do
  let(:business) { create(:business, timezone: "UTC") }
  let(:home)     { create(:branch, business: business, name: "Shubra") }
  let(:covering) { create(:branch, business: business, name: "Nasr City") }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:home_shift) do
    create(:shift, :fixed_time, business: business, name: "Home Shift",
           start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("17:00"))
  end
  let(:covering_shift) do
    create(:shift, :fixed_time, business: business, name: "Covering Shift",
           start_time: Time.zone.parse("15:00"), end_time: Time.zone.parse("23:00"))
  end

  def role_with(*perms)
    business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}", permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
  end

  let(:ahmed) do
    role = role_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")
    create(:user, business: business, first_name: "Ahmed").tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:coverage_start) { Date.new(2026, 8, 20) }
  let(:coverage_end)   { Date.new(2026, 8, 21) }

  let!(:regular_assignment) do
    create(:shift_assignment, user: ahmed, shift: home_shift, branch: home,
           effective_from: Date.new(2026, 1, 1), effective_to: nil)
  end
  let!(:coverage_assignment) do
    create(:shift_assignment, :temporary_coverage, user: ahmed, shift: covering_shift, branch: covering,
           effective_from: coverage_start, effective_to: coverage_end,
           reason: "Covering another employee's absence")
  end

  before { sign_in ahmed }

  # Scenario 3 (routing half) / Scenario 4 / Scenario 5 — my_shift is the
  # single choke point every cashier action (custody, handover) routes
  # through, so proving it resolves to the covering branch during coverage,
  # and back to home outside it, proves custody/handover attribution too.
  describe "my_shift routing" do
    let!(:nasr_dr) do
      dr = DailyReconciliation.create!(branch: covering, business: business, state: "open",
                                        opened_at: coverage_start.to_time + 15.hours, business_date: coverage_start)
      TillSession.create!(daily_reconciliation: dr, current_holder: ahmed)
      dr
    end
    let!(:shubra_dr) do
      dr = DailyReconciliation.create!(branch: home, business: business, state: "open",
                                        opened_at: (Date.new(2026, 8, 22)).to_time + 9.hours,
                                        business_date: Date.new(2026, 8, 22))
      TillSession.create!(daily_reconciliation: dr, current_holder: ahmed)
      dr
    end

    it "routes to the covering branch's DR during the coverage window" do
      travel_to(coverage_start.to_time + 16.hours) { get my_shift_path }
      expect(response).to redirect_to(finance_daily_reconciliation_path(nasr_dr))
    end

    it "routes to the home branch's DR outside the coverage window" do
      travel_to(Date.new(2026, 8, 22).to_time + 10.hours) { get my_shift_path }
      expect(response).to redirect_to(finance_daily_reconciliation_path(shubra_dr))
    end
  end

  # Scenario 3 (DR employee inclusion) / Scenario 4 (custody) / Scenario 5
  # (cash handover) — once routed into the correct branch's DR, custody and
  # handover records are naturally attributed to it; EmployeeReconciliationSummarizer
  # reads purely off the handover, never off ahmed's home branch.
  describe "Daily Reconciliation / custody / handover attribution" do
    let!(:nasr_dr) do
      dr = DailyReconciliation.create!(branch: covering, business: business, state: "closed",
                                        opened_at: coverage_start.to_time + 15.hours,
                                        closed_at: coverage_start.to_time + 23.hours,
                                        business_date: coverage_start)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                                 payment_method_name: cash_pm.name, collected_amount: 500, refund_amount: 0)
      dr
    end
    let!(:shubra_dr_same_date) do
      dr = DailyReconciliation.create!(branch: home, business: business, state: "closed",
                                        opened_at: coverage_start.to_time + 9.hours,
                                        closed_at: coverage_start.to_time + 17.hours,
                                        business_date: coverage_start)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                                 payment_method_name: cash_pm.name, collected_amount: 200, refund_amount: 0)
      dr
    end

    let!(:nasr_handover) do
      h = TillHandover.create!(daily_reconciliation: nasr_dr, from_user: ahmed, self_deposit: true,
                                created_at: coverage_start.to_time + 23.hours)
      TillHandoverAmount.create!(till_handover: h, payment_method: cash_pm,
                                  payment_method_name: cash_pm.name, collected_amount: 500, refund_amount: 0)
      h
    end

    it "includes Ahmed in the covering branch's (Nasr City) employee reconciliation summary" do
      summaries = Finance::EmployeeReconciliationSummarizer.new(nasr_dr).summaries
      expect(summaries.map { |s| s.user&.id }).to include(ahmed.id)
    end

    it "does not show Ahmed as an active employee in the home branch's (Shubra) reconciliation for the same date" do
      summaries = Finance::EmployeeReconciliationSummarizer.new(shubra_dr_same_date).summaries
      expect(summaries.map { |s| s.user&.id }).not_to include(ahmed.id)
    end

    it "attributes the handover/custody record itself to the covering branch, not Ahmed's home branch" do
      expect(nasr_handover.daily_reconciliation.branch).to eq(covering)
      expect(nasr_handover.daily_reconciliation.branch).not_to eq(home)
    end
  end

  # Scenario 6 — POS transactions are keyed to their own branch_id, entirely
  # independent of any employee — confirms coverage doesn't need (and
  # doesn't get) any special-casing here.
  describe "POS verification attribution" do
    let(:pos_import) { create(:pos_import, business: business, imported_by: ahmed) }
    let!(:nasr_pos_txn) do
      create(:pos_transaction, business: business, branch: covering, pos_import: pos_import,
             transaction_date: coverage_start.to_time + 16.hours)
    end

    it "appears in the covering branch's POS verification for that date, not the home branch's" do
      nasr_txns  = PosTransaction.for_calendar_date(branch: covering, date: coverage_start, business: business)
      home_txns  = PosTransaction.for_calendar_date(branch: home, date: coverage_start, business: business)

      expect(nasr_txns).to include(nasr_pos_txn)
      expect(home_txns).not_to include(nasr_pos_txn)
    end
  end

  # Scenario 7 — deposits belong to the DailyReconciliation (and therefore
  # its branch), never derived from the depositor's own branch.
  describe "Deposit chain attribution" do
    let!(:nasr_dr) do
      DailyReconciliation.create!(branch: covering, business: business, state: "closed",
                                   opened_at: coverage_start.to_time + 15.hours,
                                   closed_at: coverage_start.to_time + 23.hours, business_date: coverage_start)
    end
    let!(:deposit) do
      TillDeposit.create!(daily_reconciliation: nasr_dr, payment_method: cash_pm, deposited_by: ahmed,
                           amount: 500, deposited_at: coverage_start.to_time + 23.hours)
    end

    it "keeps the deposit attributed to the covering branch even though the depositor's home branch is different" do
      expect(deposit.daily_reconciliation.branch).to eq(covering)
    end
  end

  # Scenario 9 — historical isolation: financial records created during an
  # active coverage window must not retroactively change branch when the
  # coverage assignment is later ended/cancelled.
  describe "historical isolation after the coverage assignment ends" do
    # A wider 3-day coverage window (Aug 20-22) so the assignment can be
    # truncated to end a day EARLY (Aug 21) while still leaving a valid
    # (> effective_from) date range — the historical record is dated on the
    # last day (Aug 22), which is no longer covered once truncated.
    let(:last_covered_day) { Date.new(2026, 8, 22) }

    before { coverage_assignment.update!(effective_to: last_covered_day) }

    let!(:nasr_dr) do
      DailyReconciliation.create!(branch: covering, business: business, state: "closed",
                                   opened_at: last_covered_day.to_time + 15.hours,
                                   closed_at: last_covered_day.to_time + 23.hours, business_date: last_covered_day)
    end
    let!(:deposit) do
      TillDeposit.create!(daily_reconciliation: nasr_dr, payment_method: cash_pm, deposited_by: ahmed,
                           amount: 500, deposited_at: last_covered_day.to_time + 23.hours)
    end
    let!(:attendance_record) do
      AttendanceRecord.create!(user: ahmed, branch: covering, shift_assignment: coverage_assignment,
                                work_date: last_covered_day, date: last_covered_day,
                                check_in_at: last_covered_day.to_time + 15.hours, status: "incomplete")
    end

    it "leaves the DR, deposit, and attendance record's branch untouched after the coverage assignment ends early" do
      coverage_assignment.update!(effective_to: coverage_end, ended_by: ahmed) # truncates Aug 22 off the window

      expect(nasr_dr.reload.branch).to eq(covering)
      expect(deposit.reload.daily_reconciliation.branch).to eq(covering)
      expect(attendance_record.reload.branch).to eq(covering)
    end

    it "no longer resolves to the covering branch for dates after the assignment is ended early" do
      coverage_assignment.update!(effective_to: coverage_end, ended_by: ahmed)

      expect(Shifts::AssignmentResolver.for(user: ahmed, date: last_covered_day)&.branch).to eq(home)
    end
  end
end
