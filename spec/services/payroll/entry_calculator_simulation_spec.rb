require "rails_helper"

# Combined payroll simulation: every component active in a single run.
# Verifies net_salary is always the exact arithmetic result of:
#
#   net = base_salary
#         − total_deductions          (att + adj penalties)
#         + total_overtime
#         + total_bonuses             (ALL bonuses, paid or not)
#         − already_paid_total        (already-paid bonuses subtracted back)
#         − advances_deducted
#         − obligations_deducted
#
# Scenario (Jan 2025, 22 working days, 8 800 SAR/month):
#
#   daily_rate            = 8 800 / 22 = 400.00
#   −−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−
#   Attendance (20 records, 2 absent):
#     2 late days    × 100 (25% of 400) = −200
#     1 early_leave  × 200 (50% of 400) = −200
#     2 absent days  × 400              = −800   (abs-deduction via period.working_days − days_worked)
#   att_deductions                       = 1 200
#
#   Adjustments (approved):
#     cash_incentive, already_paid 500  → total_bonuses +500, already_paid_total +500
#     commission       (unpaid)    300  → total_bonuses +300
#     manual_deduction             150  → adj_deductions +150
#   adj_deductions                       =   150
#   total_deductions  = 1 200 + 150      = 1 350
#   total_bonuses     = 500 + 300        =   800
#   already_paid_total                   =   500
#
#   Advance    remaining 1 000           → advances_deducted    = 1 000
#   Obligation installment 500           → obligations_deducted =   500
#
#   net = 8 800 − 1 350 + 0 + 800 − 500 − 1 000 − 500 = 6 250
#   −−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−−

RSpec.describe Payroll::EntryCalculator, type: :service do
  # ── Setup ────────────────────────────────────────────────────────────────────

  let(:business) { create(:business, working_days_per_month: 22) }
  let(:branch)   { create(:branch, business: business) }
  let(:user)     { create(:user, business: business) }

  # Fixed period: January 2025
  let(:period) do
    create(:payroll_period,
           business:     business,
           period_year:  2025,
           period_month: 1,
           working_days: 22)
  end

  let(:period_start) { period.period_start }
  let(:period_end)   { period.period_end }

  # 09:00–17:00 shift with penalty rules
  let(:shift) do
    create(:shift, :fixed_time, business: business,
           start_time: Time.zone.parse("09:00"),
           end_time:   Time.zone.parse("17:00"),
           overtime_rate_multiplier: 1.5)
  end

  let(:shift_assignment) do
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: Date.new(2024, 6, 1))
  end

  let!(:salary_profile) do
    create(:salary_profile, :monthly, user: user, base_amount: 8_800.0,
           effective_from: Date.new(2024, 6, 1))
  end

  before { shift_assignment }

  # Penalty rules attached to the shift
  let!(:late_rule) do
    create(:penalty_rule, shift: shift,
           rule_type:       "late_arrival",
           deduction_type:  "percentage_of_daily",
           threshold_minutes: 15,
           deduction_value: 25)   # 25% of 400 = 100 SAR per trigger
  end

  let!(:early_leave_rule) do
    create(:penalty_rule, shift: shift,
           rule_type:       "early_leave",
           deduction_type:  "percentage_of_daily",
           threshold_minutes: 30,
           deduction_value: 50)   # 50% of 400 = 200 SAR per trigger
  end

  # ── Attendance records ────────────────────────────────────────────────────────
  # Jan 2025 weekdays (sample selection for exactly 20 records)

  def make_record(day, worked:, late: 0, early_leave: 0, status: "present")
    date = Date.new(2025, 1, day)
    create(:attendance_record,
           user:               user,
           branch:             branch,
           shift_assignment:   shift_assignment,
           date:               date,
           work_date:          date,
           check_in_at:        Time.zone.local(2025, 1, day, 9, 0) + late.minutes,
           check_out_at:       Time.zone.local(2025, 1, day, 17, 0) - early_leave.minutes,
           worked_minutes:     worked,
           late_minutes:       late,
           early_leave_minutes: early_leave,
           status:             status)
  end

  before do
    # 17 present days (Mon-Fri excluding chosen late/early days)
    [1, 2, 3, 9, 10, 13, 14, 15, 16, 17, 20, 21, 22, 23, 24, 27, 28].each do |day|
      make_record(day, worked: 480)
    end
    # 2 late days (Jan 6 Mon, Jan 7 Tue) — 40 min late each → 25% penalty = 100
    make_record(6, worked: 440, late: 40, status: "late")
    make_record(7, worked: 440, late: 40, status: "late")
    # 1 early-leave day (Jan 8 Wed) — 90 min early → 50% penalty = 200
    make_record(8, worked: 390, early_leave: 90, status: "early_leave")
    # 2 absent days have no records → absent_days = 22 − 20 = 2 → deduction 800
  end

  # ── Financial components ──────────────────────────────────────────────────────

  # Already-paid cash incentive (500 SAR — received in cash, NOT paid again)
  let!(:paid_incentive) do
    create(:payroll_adjustment, :cash_incentive, :already_paid,
           payroll_period: period, user: user, business: business,
           amount: 500.0)
  end

  # Unpaid commission (300 SAR — to be paid via this payroll)
  let!(:commission_adj) do
    create(:payroll_adjustment, :commission, :approved,
           payroll_period: period, user: user, business: business,
           amount: 300.0)
  end

  # Manual deduction adjustment (150 SAR — e.g., customer complaint)
  let!(:penalty_adj) do
    create(:payroll_adjustment, :manual_deduction, :approved,
           payroll_period: period, user: user, business: business,
           amount: 150.0)
  end

  # Active advance (1 000 SAR remaining)
  let!(:emp_request) do
    create(:employee_request, user: user, request_type: "salary_advance",
           status: "approved", amount: 1_000.0,
           requested_for_date: Date.new(2024, 12, 1))
  end

  let!(:advance) do
    create(:advance, user: user, employee_request: emp_request,
           total_amount: 1_000.0, remaining_amount: 1_000.0,
           issued_at: Date.new(2024, 12, 5), status: "active")
  end

  # Obligation with 500 SAR monthly installment
  let!(:obligation) do
    create(:employee_obligation,
           user: user, business: business,
           created_by: create(:user, business: business),
           total_amount: 3_000.0, remaining_amount: 3_000.0,
           installment_amount: 500.0,
           start_month: 1, start_year: 2025,
           status: "active", auto_deduct: true)
  end

  def run
    described_class.call(period: period, user: user, business: business)
  end

  # ── Core simulation ───────────────────────────────────────────────────────────

  describe "complete combined scenario — January 2025" do
    it "creates exactly one PayrollEntry" do
      expect { run }.to change(PayrollEntry, :count).by(1)
    end

    it "records base_salary as 8 800.00" do
      expect(run.base_salary).to eq(8_800.0)
    end

    it "records days_worked as 20 (17 present + 2 late + 1 early_leave)" do
      expect(run.days_worked).to eq(20)
    end

    it "records working_days as 22" do
      expect(run.working_days).to eq(22)
    end

    it "records total_deductions as 1 350 (att 1 200 + adj 150)" do
      expect(run.total_deductions).to eq(1_350.0)
    end

    it "records total_bonuses as 800 (paid incentive 500 + commission 300)" do
      expect(run.total_bonuses).to eq(800.0)
    end

    it "records already_paid_total as 500" do
      expect(run.already_paid_total).to eq(500.0)
    end

    it "records advances_deducted as 1 000" do
      expect(run.advances_deducted).to eq(1_000.0)
    end

    it "records obligations_deducted as 500" do
      expect(run.obligations_deducted).to eq(500.0)
    end

    it "calculates net_salary as exactly 6 250.00" do
      # 8800 − 1350 + 0 + 800 − 500 − 1000 − 500 = 6250
      expect(run.net_salary).to eq(6_250.0)
    end

    it "satisfies the net formula exactly" do
      entry = run
      expected = entry.base_salary \
                 - entry.total_deductions \
                 + entry.total_overtime \
                 + entry.total_bonuses \
                 - entry.already_paid_total \
                 - entry.advances_deducted \
                 - entry.obligations_deducted
      expect(entry.net_salary).to be_within(0.01).of(expected)
    end
  end

  # ── Line-item breakdown ───────────────────────────────────────────────────────

  describe "line-item composition" do
    let(:entry) { run }

    it "creates 2 late_penalty items (one per late day)" do
      expect(entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(2)
    end

    it "each late_penalty is −100 SAR (25% of daily rate 400)" do
      amounts = entry.payroll_line_items.where(item_type: "late_penalty").pluck(:amount)
      expect(amounts).to all(eq(-100.0))
    end

    it "creates 1 early_leave_penalty item at −200 SAR" do
      item = entry.payroll_line_items.find_by(item_type: "early_leave_penalty")
      expect(item).to be_present
      expect(item.amount).to eq(-200.0)
    end

    it "creates 1 absence deduction item at −800 SAR (2 days × 400)" do
      item = entry.payroll_line_items.find_by(item_type: "manual_adjustment")
      expect(item).to be_present
      expect(item.amount).to eq(-800.0)
    end

    it "creates 1 cash_incentive item flagged already_paid with amount +500" do
      item = entry.payroll_line_items.find_by(item_type: "cash_incentive")
      expect(item).to be_present
      expect(item.amount).to eq(500.0)
      expect(item.already_paid).to be true
    end

    it "creates 1 commission item (not already_paid) with amount +300" do
      item = entry.payroll_line_items.find_by(item_type: "commission")
      expect(item).to be_present
      expect(item.amount).to eq(300.0)
      expect(item.already_paid).to be false
    end

    it "creates 1 manual_deduction adjustment item at −150 SAR" do
      item = entry.payroll_line_items.find_by(item_type: "manual_deduction")
      expect(item).to be_present
      expect(item.amount).to eq(-150.0)
    end

    it "creates 1 advance_deduction item at −1 000 SAR" do
      item = entry.payroll_line_items.find_by(item_type: "advance_deduction")
      expect(item).to be_present
      expect(item.amount).to eq(-1_000.0)
    end

    it "creates 1 obligation_deduction item at −500 SAR" do
      item = entry.payroll_line_items.find_by(item_type: "obligation_deduction")
      expect(item).to be_present
      expect(item.amount).to eq(-500.0)
    end
  end

  # ── Regeneration idempotence ──────────────────────────────────────────────────

  describe "regeneration idempotence" do
    it "produces the same net_salary on a second run after clearing state" do
      first = run
      first_net = first.net_salary

      # Simulate what PeriodGenerator does on regeneration:
      # destroy ObligationDeduction snapshots first (before_destroy restores balances),
      # then destroy the entry (cascades to line items).
      ObligationDeduction.where(payroll_period: period).destroy_all
      first.destroy!

      second = run
      expect(second.net_salary).to eq(first_net)
    end

    it "produces identical totals on the second run" do
      first = run
      ObligationDeduction.where(payroll_period: period).destroy_all
      first.destroy!

      second = run
      expect(second.base_salary).to         eq(first.base_salary)
      expect(second.total_deductions).to     eq(first.total_deductions)
      expect(second.total_bonuses).to        eq(first.total_bonuses)
      expect(second.already_paid_total).to   eq(first.already_paid_total)
      expect(second.advances_deducted).to    eq(first.advances_deducted)
      expect(second.obligations_deducted).to eq(first.obligations_deducted)
    end

    it "restores obligation balance after snapshot destruction so the second run deducts correctly" do
      pre_run_remaining = obligation.remaining_amount  # 3 000 (not yet decremented)

      first = run  # first run decrements remaining → 2 500
      expect(obligation.reload.remaining_amount).to eq(pre_run_remaining - 500.0)

      # Destroy snapshots (before_destroy restores the balance) + entry (uniqueness guard)
      ObligationDeduction.where(payroll_period: period).destroy_all
      first.destroy!
      expect(obligation.reload.remaining_amount).to eq(pre_run_remaining)

      # Second run decrements again — same result
      run
      expect(obligation.reload.remaining_amount).to eq(pre_run_remaining - 500.0)
    end
  end

  # ── recalculate_totals! ───────────────────────────────────────────────────────

  describe "PayrollEntry#recalculate_totals!" do
    let(:entry) { run }

    it "adjusts net_salary correctly when a new approved bonus line item is added" do
      # Add a new 200 SAR cash incentive (not already paid)
      entry.payroll_line_items.create!(
        item_type: "cash_incentive", amount: 200.0,
        description: "Spot bonus", review_status: "approved"
      )

      entry.recalculate_totals!
      entry.reload

      # total_bonuses: 800 (original) + 200 (new) = 1 000
      # already_paid_total: still 500
      # net: 8800 − 1350 + 0 + 1000 − 500 − 1000 − 500 = 6 450
      expect(entry.total_bonuses).to eq(1_000.0)
      expect(entry.net_salary).to    eq(6_450.0)
    end

    it "satisfies the net formula after recalculation" do
      entry.payroll_line_items.create!(
        item_type: "manual_deduction", amount: -300.0,
        description: "Additional penalty", review_status: "approved"
      )
      entry.recalculate_totals!
      entry.reload

      expected = entry.base_salary \
                 - entry.total_deductions \
                 + entry.total_overtime \
                 + entry.total_bonuses \
                 - entry.already_paid_total \
                 - entry.advances_deducted \
                 - entry.obligations_deducted
      expect(entry.net_salary).to be_within(0.01).of(expected)
    end

    it "does not count pending line items toward net_salary" do
      entry.payroll_line_items.create!(
        item_type: "late_penalty", amount: -50.0,
        description: "Pending review item", review_status: "pending_review"
      )
      entry.recalculate_totals!
      entry.reload

      # net unchanged — pending item excluded
      expect(entry.net_salary).to eq(6_250.0)
    end
  end

  # ── Edge cases in the combined scenario ──────────────────────────────────────

  describe "approved late_permission reduces penalty for one of the late days" do
    before do
      # Permission covers 40 min for Jan 6 → no penalty for that day
      create(:employee_request, :late_permission, :approved, user: user,
             requested_for_date: Date.new(2025, 1, 6), duration_minutes: 40)
    end

    it "creates only 1 late_penalty item (Jan 7 remains penalised)" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(1)
    end

    it "reduces total_deductions by 100 (one penalty waived)" do
      entry = run
      # att_deductions: 100 (one late) + 200 (early_leave) + 800 (absence) = 1 100
      # adj_deductions: 150
      # total: 1 250
      expect(entry.total_deductions).to eq(1_250.0)
    end

    it "increases net_salary by 100 compared to the full-penalty scenario" do
      entry = run
      expect(entry.net_salary).to eq(6_350.0)
    end
  end

  describe "pending adjustment is excluded from the calculation" do
    before do
      # Add a large pending bonus — should have zero effect
      create(:payroll_adjustment, :cash_incentive,
             payroll_period: period, user: user, business: business,
             amount: 2_000.0, review_status: :pending_review)
    end

    it "does not change net_salary" do
      expect(run.net_salary).to eq(6_250.0)
    end
  end
end
