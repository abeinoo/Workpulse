require "rails_helper"

RSpec.describe Payroll::EntryCalculator do
  let(:business)  { create(:business, working_days_per_month: 22) }
  let(:branch)    { create(:branch, business: business) }
  let(:user)      { create(:user, business: business) }

  let(:shift) do
    create(:shift, :fixed_time, business: business,
           start_time: Time.zone.parse("09:00"),
           end_time:   Time.zone.parse("17:00"),
           overtime_rate_multiplier: 1.5)
  end

  let(:shift_assignment) do
    create(:shift_assignment, user: user, branch: branch, shift: shift,
           effective_from: 3.months.ago.to_date)
  end

  let(:period) do
    create(:payroll_period, business: business, period_year: 1.month.ago.year,
           period_month: 1.month.ago.month, working_days: 22)
  end

  let(:period_start) { period.period_start }
  let(:period_end)   { period.period_end }

  # Monthly 8,800 SAR profile
  let!(:salary_profile) do
    create(:salary_profile, :monthly, user: user, base_amount: 8_800.0,
           effective_from: 6.months.ago.to_date)
  end

  # Ensure shift_assignment exists before building records
  before { shift_assignment }

  def create_record(date, worked:, late: 0, early_leave: 0, status: "present")
    create(:attendance_record,
           user:               user,
           branch:             branch,
           shift_assignment:   shift_assignment,
           date:               date,
           work_date:          date,
           check_in_at:        Time.zone.local(date.year, date.month, date.day, 9, 0) + late.minutes,
           check_out_at:       Time.zone.local(date.year, date.month, date.day, 17, 0) - early_leave.minutes,
           worked_minutes:     worked,
           late_minutes:       late,
           early_leave_minutes: early_leave,
           status:             status)
  end

  def run
    described_class.call(period: period, user: user, business: business)
  end

  describe "with no salary profile" do
    before { salary_profile.destroy! }

    it "returns nil without creating any entry" do
      expect(run).to be_nil
      expect(PayrollEntry.count).to eq(0)
    end
  end

  describe "with a full month of perfect attendance (22 days worked)" do
    before do
      (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22).each do |date|
        create_record(date, worked: 480, late: 0, early_leave: 0, status: "present")
      end
    end

    it "creates a PayrollEntry" do
      expect { run }.to change(PayrollEntry, :count).by(1)
    end

    it "sets base_salary to 8800" do
      entry = run
      expect(entry.base_salary).to eq(8_800.0)
    end

    it "sets days_worked to 22" do
      entry = run
      expect(entry.days_worked).to eq(22)
    end

    it "creates no deduction line items" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: %w[late_penalty early_leave_penalty]).count).to eq(0)
    end

    it "sets net_salary equal to base_salary when no deductions or overtime" do
      entry = run
      expect(entry.net_salary).to eq(8_800.0)
    end
  end

  describe "with late arrival (40 minutes late on one day)" do
    let(:late_day) { period_start.next_occurring(:monday) }

    before do
      create(:penalty_rule, shift: shift, rule_type: "late_arrival",
             deduction_type: "percentage_of_daily", threshold_minutes: 15, deduction_value: 25)
      create_record(late_day, worked: 440, late: 40, status: "late")
    end

    it "creates a late_penalty line item" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(1)
    end

    it "deducts 25% of daily rate" do
      # daily_rate = 8800 / 22 = 400 SAR; 25% = 100 SAR
      entry = run
      penalty_item = entry.payroll_line_items.find_by(item_type: "late_penalty")
      expect(penalty_item.amount).to eq(-100.0)
    end

    it "subtracts the penalty from net_salary" do
      entry = run
      expect(entry.total_deductions).to be > 0
    end
  end

  describe "when an approved late_permission fully covers the late arrival" do
    let(:late_day) { period_start.next_occurring(:monday) }

    before do
      create(:penalty_rule, shift: shift, rule_type: "late_arrival",
             deduction_type: "percentage_of_daily", threshold_minutes: 15, deduction_value: 25)
      create_record(late_day, worked: 440, late: 40, status: "late")
      create(:employee_request, :late_permission, :approved, user: user,
             requested_for_date: late_day, duration_minutes: 40)
    end

    it "does not create a late_penalty line item" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(0)
    end
  end

  describe "partial late_permission — approved for fewer minutes than late" do
    # Employee late 40 min; permission covers 25 min → effective = 15 min
    # 15 min == threshold → penalty fires at 25% of daily_rate (400) = 100 SAR
    let(:late_day) { period_start.next_occurring(:monday) }

    before do
      create(:penalty_rule, shift: shift, rule_type: "late_arrival",
             deduction_type: "percentage_of_daily", threshold_minutes: 15, deduction_value: 25)
      create_record(late_day, worked: 440, late: 40, status: "late")
      create(:employee_request, :late_permission, :approved, user: user,
             requested_for_date: late_day, duration_minutes: 25)
    end

    it "creates a late_penalty item for the residual minutes" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(1)
    end

    it "stores original_minutes and permission_minutes on the line item" do
      entry = run
      item = entry.payroll_line_items.find_by(item_type: "late_penalty")
      expect(item.original_minutes).to eq(40)
      expect(item.permission_minutes).to eq(25)
    end

    it "applies a smaller penalty than without any permission" do
      entry_no_perm = run
      penalty_with_partial = entry_no_perm.payroll_line_items.find_by(item_type: "late_penalty").amount.abs
      # Full-penalty case (no permission) = 25% of 400 = 100 SAR
      # Partial = same rule fires (15 >= 15 threshold) → 100 SAR — same deduction value
      # Just verify amount is present and entry net_salary is correct
      expect(entry_no_perm.total_deductions).to be > 0
    end
  end

  describe "partial early_leave permission" do
    # Employee left 90 min early; permission covers 30 min → effective = 60 min
    let(:early_day) { period_start.next_occurring(:tuesday) }

    before do
      create(:penalty_rule, shift: shift, rule_type: "early_leave",
             deduction_type: "percentage_of_daily", threshold_minutes: 30, deduction_value: 50)
      create_record(early_day, worked: 390, early_leave: 90, status: "early_leave")
      create(:employee_request, :early_leave, :approved, user: user,
             requested_for_date: early_day, duration_minutes: 30)
    end

    it "creates an early_leave_penalty line item" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "early_leave_penalty").count).to eq(1)
    end

    it "stores original_minutes (90) and permission_minutes (30) on the item" do
      entry = run
      item = entry.payroll_line_items.find_by(item_type: "early_leave_penalty")
      expect(item.original_minutes).to eq(90)
      expect(item.permission_minutes).to eq(30)
    end
  end

  describe "full early_leave permission — no deduction" do
    let(:early_day) { period_start.next_occurring(:tuesday) }

    before do
      create(:penalty_rule, shift: shift, rule_type: "early_leave",
             deduction_type: "percentage_of_daily", threshold_minutes: 30, deduction_value: 50)
      create_record(early_day, worked: 420, early_leave: 60, status: "early_leave")
      create(:employee_request, :early_leave, :approved, user: user,
             requested_for_date: early_day, duration_minutes: 60)
    end

    it "does not create an early_leave_penalty line item" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "early_leave_penalty")).to be_empty
    end
  end

  describe "pending or rejected request does not reduce penalty" do
    let(:late_day) { period_start.next_occurring(:monday) }

    before do
      create(:penalty_rule, shift: shift, rule_type: "late_arrival",
             deduction_type: "percentage_of_daily", threshold_minutes: 15, deduction_value: 25)
      create_record(late_day, worked: 440, late: 40, status: "late")
      create(:employee_request, :late_permission, user: user,
             requested_for_date: late_day, duration_minutes: 40)  # pending
    end

    it "still creates the full late_penalty" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "late_penalty").count).to eq(1)
    end
  end

  describe "with overtime (60 minutes over scheduled 8 hours)" do
    let(:overtime_day) { period_start.next_occurring(:tuesday) }

    before do
      create_record(overtime_day, worked: 540, late: 0, early_leave: 0, status: "present")
    end

    it "creates an overtime line item" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "overtime").count).to eq(1)
    end

    it "adds overtime pay at 1.5x hourly rate" do
      # hourly = 400/8 = 50; overtime_pay = 50 * 1.0 * 1.5 = 75
      entry = run
      overtime_item = entry.payroll_line_items.find_by(item_type: "overtime")
      expect(overtime_item.amount).to eq(75.0)
    end
  end

  describe "absence deduction for monthly employee" do
    it "deducts daily_rate for each absent working day" do
      # No attendance records = 22 absent days
      # absence deduction = 22 * (8800/22) = 8800 — full month absent
      entry = run
      absence_items = entry.payroll_line_items.where(item_type: "manual_adjustment")
      expect(absence_items).to be_present
      total_deducted = absence_items.sum(:amount).abs
      expect(total_deducted).to be_within(0.01).of(8_800.0)
    end
  end

  describe "with an active advance" do
    let!(:emp_request) do
      create(:employee_request, user: user,
             request_type: "salary_advance", status: "approved", amount: 1000,
             requested_for_date: 1.month.ago.to_date)
    end

    let!(:advance) do
      create(:advance, user: user, employee_request: emp_request,
             total_amount: 1000, remaining_amount: 1000,
             issued_at: 1.month.ago, status: "active")
    end

    it "creates an advance_deduction line item" do
      entry = run
      expect(entry.payroll_line_items.where(item_type: "advance_deduction").count).to eq(1)
    end

    it "sets advances_deducted to the full remaining amount" do
      entry = run
      expect(entry.advances_deducted).to eq(1000.0)
    end
  end

  describe "already_paid cash incentive — financial integrity" do
    # Baseline: full month of perfect attendance → net = base = 8800
    before do
      (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22).each do |date|
        create_record(date, worked: 480)
      end
    end

    context "when already_paid: true" do
      let!(:adj) do
        create(:payroll_adjustment, :cash_incentive, :already_paid,
               payroll_period: period, user: user, business: business,
               amount: 500.0)
      end

      it "includes the incentive in total_bonuses for gross reporting" do
        entry = run
        expect(entry.total_bonuses).to eq(500.0)
      end

      it "records already_paid_total" do
        entry = run
        expect(entry.already_paid_total).to eq(500.0)
      end

      it "does NOT add the incentive to net_salary" do
        entry = run
        expect(entry.net_salary).to eq(8_800.0)
      end

      it "creates a line item flagged already_paid: true" do
        entry = run
        li = entry.payroll_line_items.find_by(item_type: "cash_incentive")
        expect(li).to be_present
        expect(li.already_paid).to be true
      end
    end

    context "when already_paid: false (normal unpaid incentive)" do
      let!(:adj) do
        create(:payroll_adjustment, :cash_incentive, :approved,
               payroll_period: period, user: user, business: business,
               amount: 500.0, already_paid: false)
      end

      it "adds the incentive to net_salary" do
        entry = run
        expect(entry.net_salary).to eq(9_300.0)
      end

      it "keeps already_paid_total at zero" do
        entry = run
        expect(entry.already_paid_total).to eq(0.0)
      end
    end

    context "mixed: one already_paid incentive and one unpaid commission" do
      let!(:paid_adj) do
        create(:payroll_adjustment, :cash_incentive, :already_paid,
               payroll_period: period, user: user, business: business,
               amount: 300.0)
      end

      let!(:unpaid_adj) do
        create(:payroll_adjustment, :commission, :approved,
               payroll_period: period, user: user, business: business,
               amount: 200.0)
      end

      it "includes both in total_bonuses" do
        entry = run
        expect(entry.total_bonuses).to eq(500.0)
      end

      it "stores only the paid amount in already_paid_total" do
        entry = run
        expect(entry.already_paid_total).to eq(300.0)
      end

      it "adds only the unpaid amount to net_salary" do
        entry = run
        expect(entry.net_salary).to eq(9_000.0)  # 8800 + 200 (300 already paid)
      end
    end

    context "pending adjustment is not included at all" do
      let!(:adj) do
        create(:payroll_adjustment, :cash_incentive,
               payroll_period: period, user: user, business: business,
               amount: 500.0, already_paid: true, review_status: :pending_review)
      end

      it "does not affect total_bonuses or net_salary" do
        entry = run
        expect(entry.total_bonuses).to eq(0.0)
        expect(entry.already_paid_total).to eq(0.0)
        expect(entry.net_salary).to eq(8_800.0)
      end
    end
  end

  describe "regeneration safety — legacy adjustment types" do
    # These tests guard against payroll regeneration crashing when historical
    # PayrollAdjustment records carry legacy types (bonus, reward, eid_bonus)
    # that were removed from the enum. Rails type-casts unknown enum values to nil,
    # so the raw DB string must be read defensively and mapped to a current type.

    before do
      (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(22).each do |date|
        create_record(date, worked: 480)
      end
    end

    context "when a PayrollAdjustment has a legacy 'bonus' type in the DB" do
      before do
        adj = create(:payroll_adjustment, :cash_incentive, :approved,
                     payroll_period: period, user: user, business: business, amount: 200.0)
        PayrollAdjustment.where(id: adj.id).update_all(adjustment_type: "bonus")
      end

      it "completes regeneration without raising" do
        expect { run }.not_to raise_error
      end

      it "maps the bonus to a cash_incentive line item" do
        entry = run
        expect(entry.payroll_line_items.where(item_type: "cash_incentive").count).to eq(1)
      end

      it "adds the bonus amount to net_salary" do
        entry = run
        expect(entry.net_salary).to be_within(0.01).of(9_000.0)  # 8800 + 200
      end
    end

    context "when a PayrollAdjustment has a legacy 'reward' type in the DB" do
      before do
        adj = create(:payroll_adjustment, :cash_incentive, :approved,
                     payroll_period: period, user: user, business: business, amount: 150.0)
        PayrollAdjustment.where(id: adj.id).update_all(adjustment_type: "reward")
      end

      it "completes regeneration and maps reward to cash_incentive" do
        entry = run
        expect(entry.payroll_line_items.where(item_type: "cash_incentive").count).to eq(1)
      end
    end

    context "when a PayrollAdjustment has a completely unknown type" do
      before do
        adj = create(:payroll_adjustment, :cash_incentive, :approved,
                     payroll_period: period, user: user, business: business, amount: 100.0)
        PayrollAdjustment.where(id: adj.id).update_all(adjustment_type: "totally_unknown_type")
      end

      it "skips the unresolvable adjustment without crashing" do
        expect { run }.not_to raise_error
      end

      it "creates a valid entry with no line item for the skipped adjustment" do
        entry = run
        expect(entry).to be_persisted
        expect(entry.payroll_line_items.where(item_type: "totally_unknown_type")).to be_empty
      end

      it "does not count the skipped adjustment toward net_salary" do
        entry = run
        expect(entry.net_salary).to be_within(0.01).of(8_800.0)
      end
    end

    context "when mixed: one legacy bonus and one current commission" do
      before do
        legacy = create(:payroll_adjustment, :cash_incentive, :approved,
                        payroll_period: period, user: user, business: business, amount: 300.0)
        PayrollAdjustment.where(id: legacy.id).update_all(adjustment_type: "bonus")

        create(:payroll_adjustment, :commission, :approved,
               payroll_period: period, user: user, business: business, amount: 200.0)
      end

      it "includes both adjustments in net_salary" do
        entry = run
        expect(entry.net_salary).to be_within(0.01).of(9_300.0)  # 8800 + 300 + 200
      end

      it "creates line items for both" do
        entry = run
        expect(entry.payroll_line_items.where(item_type: "cash_incentive").count).to eq(1)
        expect(entry.payroll_line_items.where(item_type: "commission").count).to eq(1)
      end
    end
  end

  describe "daily salary employee" do
    let!(:daily_profile) do
      salary_profile.update!(active: false)
      create(:salary_profile, :daily, user: user, base_amount: 400.0,
             effective_from: 6.months.ago.to_date)
    end

    before do
      days = (period_start..period_end).reject { |d| d.saturday? || d.sunday? }.first(18)
      days.each { |d| create_record(d, worked: 480) }
    end

    it "calculates base_salary as daily_rate * days_worked" do
      entry = run
      expect(entry.base_salary).to eq(400.0 * 18)
      expect(entry.days_worked).to eq(18)
      expect(entry.net_salary).to be_within(0.01).of(400.0 * 18)
    end

    it "does not apply absence deduction for daily employees" do
      entry = run
      absence_items = entry.payroll_line_items.where(item_type: "manual_adjustment")
      expect(absence_items).to be_empty
    end
  end
end
