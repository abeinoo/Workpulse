require "rails_helper"

# AP-D5 (found in Milestone 2 Pilot 2 M0): reassigning an obligation from
# employee A to employee B rebuilt only B's open payroll entry, so A's draft
# entry kept the obligation deduction while B's gained it — a double deduction.
# Payroll::ObligationEditor now rebuilds both employees' open entries.
RSpec.describe "Payroll correctness after obligation reassignment", type: :request do
  around { |example| travel_to(Time.zone.local(2026, 6, 15, 12)) { example.run } }

  let(:business)   { create(:business) }
  let(:other)      { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let(:employee_a) { create(:user, business: business) }
  let(:employee_b) { create(:user, business: business) }
  let(:period)     { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22) }

  let!(:obligation) do
    create(:employee_obligation, user: employee_a, business: business, created_by: owner,
                                 start_month: 6, start_year: 2026,
                                 total_amount: 1_500, remaining_amount: 1_500, installment_amount: 500)
  end

  def calculate(user)
    create(:salary_profile, :monthly, user: user, base_amount: 8_800, effective_from: 1.year.ago.to_date)
    Payroll::EntryCalculator.call(period: period, user: user, business: business)
  end

  def entry_for(user) = PayrollEntry.find_by(payroll_period: period, user: user)

  def obligation_lines(user)
    entry_for(user).payroll_line_items.where(item_type: "obligation_deduction")
  end

  def reassign_to(user)
    patch admin_employee_obligation_path(obligation), params: { employee_obligation: { user_id: user.id } }
  end

  before { sign_in owner }

  context "when both employees have an open payroll entry" do
    before do
      calculate(employee_a)
      calculate(employee_b)
    end

    it "deducts the obligation from employee A while it is assigned to A" do
      expect(entry_for(employee_a).obligations_deducted).to eq(500)
      expect(entry_for(employee_b).obligations_deducted).to eq(0)
    end

    it "moves the deduction from A to B on reassignment" do
      reassign_to(employee_b)

      expect(response).to redirect_to(admin_employee_obligation_path(obligation))
      expect(obligation.reload.user).to eq(employee_b)
      expect(entry_for(employee_a).reload.obligations_deducted).to eq(0)
      expect(obligation_lines(employee_a)).to be_empty
      expect(entry_for(employee_b).reload.obligations_deducted).to eq(500)
      expect(obligation_lines(employee_b).count).to eq(1)
    end

    it "never deducts twice: one snapshot, balance decremented once" do
      reassign_to(employee_b)

      total = PayrollEntry.where(payroll_period: period).sum(:obligations_deducted)
      expect(total).to eq(500)
      expect(ObligationDeduction.where(employee_obligation: obligation).count).to eq(1)
      expect(obligation.reload.remaining_amount).to eq(1_000)
    end
  end

  context "when the new employee has no payroll entry in the open period" do
    before { calculate(employee_a) }

    it "removes A's deduction, creates no entry for B and restores the balance" do
      reassign_to(employee_b)

      expect(entry_for(employee_a).reload.obligations_deducted).to eq(0)
      expect(entry_for(employee_b)).to be_nil
      expect(ObligationDeduction.where(employee_obligation: obligation)).to be_empty
      expect(obligation.reload.remaining_amount).to eq(1_500)
    end
  end

  it "still refuses a reassignment to another business's employee (A keeps the deduction)" do
    calculate(employee_a)

    reassign_to(create(:user, business: other))

    expect(response).to redirect_to(root_path)
    expect(obligation.reload.user).to eq(employee_a)
    expect(entry_for(employee_a).reload.obligations_deducted).to eq(500)
  end

  it "keeps the ordinary edit path (same employee) unchanged" do
    calculate(employee_a)

    patch admin_employee_obligation_path(obligation), params: { employee_obligation: { installment_amount: 300 } }

    expect(entry_for(employee_a).reload.obligations_deducted).to eq(300)
    expect(obligation.reload.remaining_amount).to eq(1_200)
  end
end
