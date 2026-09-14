require "rails_helper"

# Regression coverage for the investigation into "is September payroll using
# August's salary/advance data?" The trace found a single root cause — the
# AdvanceDeductor cross-period duplicate fix in Payroll::AdvanceDeductor — and
# no separate bug in salary-rate anchoring or advance-limit calculation. These
# specs pin that down so a future change can't reintroduce either problem.
RSpec.describe "Advance/payroll period isolation" do
  let(:business) { create(:business, working_days_per_month: 22, max_salary_advance_percentage: 30) }
  let(:branch)   { create(:branch, business: business) }
  let(:user)     { create(:user, business: business) }

  let(:august)    { create(:payroll_period, :finalized, business: business, period_year: 2026, period_month: 8, working_days: 22) }
  let(:september) { create(:payroll_period, business: business, period_year: 2026, period_month: 9, working_days: 22) }

  # 1 & 2. September payroll must use September's salary data, not August's —
  # proven by giving the employee two salary profiles and checking each
  # period's entry picks up the profile that was actually effective for it.
  describe "salary basis used for the advance/payroll calculation" do
    let!(:august_profile) do
      create(:salary_profile, :monthly, user: user, base_amount: 5_000.0,
             effective_from: Date.new(2026, 6, 1))
    end

    let!(:september_profile) do
      create(:salary_profile, :monthly, user: user, base_amount: 7_000.0,
             effective_from: Date.new(2026, 9, 1))
    end

    it "anchors August's entry to the salary profile effective in August, not September's later one" do
      entry = Payroll::EntryCalculator.call(period: august, user: user, business: business)
      expect(entry.base_salary).to eq(5_000.0)
    end

    it "anchors September's entry to the salary profile effective in September, not August's earlier one" do
      entry = Payroll::EntryCalculator.call(period: september, user: user, business: business)
      expect(entry.base_salary).to eq(7_000.0)
    end
  end

  # 3. An advance created in August whose repayment is only picked up in
  # September (because August never got the chance to generate first) belongs
  # to September.
  describe "an August-created advance with no prior claim" do
    let!(:salary_profile) do
      create(:salary_profile, :monthly, user: user, base_amount: 5_000.0, effective_from: Date.new(2026, 1, 1))
    end

    let!(:advance) do
      create(:advance, user: user, total_amount: 900.0, remaining_amount: 900.0,
             issued_at: Date.new(2026, 8, 20))
    end

    it "is deducted in September when September is the first period to claim it" do
      entry = Payroll::EntryCalculator.call(period: september, user: user, business: business)

      expect(entry.payroll_line_items.where(item_type: "advance_deduction").count).to eq(1)
      expect(entry.advances_deducted).to eq(900.0)
    end
  end

  # A September-issued advance, claimed for the first time by September itself,
  # must appear in September — the flip side of "September must not re-claim
  # August's advance."
  describe "an advance issued in September" do
    let!(:salary_profile) do
      create(:salary_profile, :monthly, user: user, base_amount: 5_000.0, effective_from: Date.new(2026, 1, 1))
    end

    let!(:advance) do
      create(:advance, user: user, total_amount: 600.0, remaining_amount: 600.0,
             issued_at: Date.new(2026, 9, 5))
    end

    it "is deducted in September" do
      entry = Payroll::EntryCalculator.call(period: september, user: user, business: business)

      expect(entry.payroll_line_items.where(item_type: "advance_deduction").count).to eq(1)
      expect(entry.advances_deducted).to eq(600.0)
    end
  end

  # 4. An advance already claimed by a finalized-but-unpaid August entry must
  # never be re-deducted when September is generated. This is the exact
  # scenario from the reported screenshot: advance #131/#154 (issued in
  # August) kept reappearing in a September PayrollEntry's deductions table
  # because the old AdvanceDeductor had no memory of August's claim.
  describe "an advance already claimed by August (the screenshot scenario)" do
    let!(:salary_profile) do
      create(:salary_profile, :monthly, user: user, base_amount: 5_000.0, effective_from: Date.new(2026, 1, 1))
    end

    let!(:advance) do
      create(:advance, user: user, total_amount: 2_307.0, remaining_amount: 2_307.0,
             issued_at: Date.new(2026, 8, 16))
    end

    it "is not deducted again in September" do
      august_entry = Payroll::EntryCalculator.call(period: august, user: user, business: business)
      expect(august_entry.advances_deducted).to eq(2_307.0)

      september_entry = Payroll::EntryCalculator.call(period: september, user: user, business: business)

      expect(september_entry.payroll_line_items.where(item_type: "advance_deduction")).to be_empty
      expect(september_entry.advances_deducted).to eq(0.0)
    end

    # Reproduces the screenshot at the exact granularity the UI table reads
    # from (PayrollEntriesController#show groups @deductions by
    # PayrollLineItem, not by the aggregate advances_deducted total) — so this
    # fails if a future change satisfies the total but leaves a stray row.
    it "leaves no advance_deduction PayrollLineItem tied to the September entry, while August's stays intact" do
      august_entry    = Payroll::EntryCalculator.call(period: august, user: user, business: business)
      september_entry = Payroll::EntryCalculator.call(period: september, user: user, business: business)

      september_rows = PayrollLineItem.where(payroll_entry: september_entry, item_type: "advance_deduction",
                                              source_type: "Advance", source_id: advance.id)
      august_rows    = PayrollLineItem.where(payroll_entry: august_entry, item_type: "advance_deduction",
                                              source_type: "Advance", source_id: advance.id)

      expect(september_rows).to be_empty
      expect(august_rows.count).to eq(1)
      expect(august_rows.first.amount).to eq(-2_307.0)
    end
  end

  # 5. The advance LIMIT calculation (Salary::AdvanceEligibilityCalculator,
  # used only on the "request a new advance" form) is a real-time eligibility
  # check and has no PayrollPeriod dependency at all — it must not be affected
  # by which payroll periods exist, their status, or which period a prior
  # advance was deducted in.
  describe "advance limit calculation is independent of payroll period state" do
    around { |ex| travel_to(Time.zone.local(2026, 9, 14, 12, 0, 0)) { ex.run } }

    let!(:salary_profile) do
      create(:salary_profile, :monthly, user: user, base_amount: 6_600.0,
             effective_from: Date.new(2026, 1, 1))
    end

    # A "paid" request (mirrors Requests::Approver#pay in production) so the
    # amount is counted once via Advance#remaining_amount — an "approved but
    # not yet paid" request would additionally count toward pending_balance.
    let!(:paid_request) do
      create(:employee_request, :salary_advance, user: user, amount: 500.0, status: "paid")
    end

    let!(:advance) do
      create(:advance, user: user, employee_request: paid_request,
             total_amount: 500.0, remaining_amount: 500.0,
             issued_at: Date.new(2026, 8, 16))
    end

    it "produces the same limit result whether or not any payroll period has been generated" do
      before_result = Salary::AdvanceEligibilityCalculator.for(user: user)

      Payroll::EntryCalculator.call(period: august, user: user, business: business)
      Payroll::EntryCalculator.call(period: september, user: user, business: business)

      after_result = Salary::AdvanceEligibilityCalculator.for(user: user)

      expect(after_result.max_amount).to eq(before_result.max_amount)
      expect(after_result.outstanding).to eq(before_result.outstanding)
      expect(after_result.available).to eq(before_result.available)
    end

    it "excludes the advance from outstanding once it belongs to a prior calendar month, regardless of which period deducted it" do
      Payroll::EntryCalculator.call(period: august, user: user, business: business)

      result = Salary::AdvanceEligibilityCalculator.for(user: user)

      # Business rule: new-advance eligibility is monthly-independent —
      # outstanding only counts advances issued THIS calendar month. This
      # advance was issued in August (2026-08-16), a prior month relative to
      # whenever this spec actually runs, so it must not suppress the current
      # month's eligibility — regardless of remaining_amount or which payroll
      # period claimed its deduction line item.
      expect(result.outstanding).to eq(0.0)
    end
  end
end
