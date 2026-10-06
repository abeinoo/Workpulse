require "rails_helper"

# AP-D4 (found in Milestone 2 Pilot 2 M0): pausing or cancelling an obligation
# only flipped its status, so an already-calculated draft payroll entry kept
# deducting it until the period was regenerated (and a resumed obligation was
# missing). The status change now rebuilds the employee's open payroll entries
# in the same transaction; finalized/paid periods stay untouched.
RSpec.describe "Payroll correctness after obligation pause / resume / cancel", type: :request do
  around { |example| travel_to(Time.zone.local(2026, 6, 15, 12)) { example.run } }

  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let(:employee)  { create(:user, business: business) }
  let(:colleague) { create(:user, business: business) }
  let(:period)    { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22) }

  let!(:obligation) do
    create(:employee_obligation, user: employee, business: business, created_by: owner,
                                 start_month: 6, start_year: 2026,
                                 total_amount: 1_500, remaining_amount: 1_500, installment_amount: 500)
  end

  before do
    [ employee, colleague ].each do |user|
      create(:salary_profile, :monthly, user: user, base_amount: 8_800, effective_from: 1.year.ago.to_date)
      Payroll::EntryCalculator.call(period: period, user: user, business: business)
    end
    sign_in owner
  end

  def entry_for(user) = PayrollEntry.find_by!(payroll_period: period, user: user)

  def obligation_line_items(user)
    entry_for(user).payroll_line_items.where(item_type: "obligation_deduction")
  end

  it "deducts an active obligation normally" do
    expect(entry_for(employee).obligations_deducted).to eq(500)
    expect(obligation_line_items(employee).count).to eq(1)
    expect(obligation.reload.remaining_amount).to eq(1_000)
  end

  it "stops deducting a paused obligation from the open payroll entry and restores the balance" do
    patch pause_admin_employee_obligation_path(obligation)

    expect(obligation.reload).to be_paused
    expect(entry_for(employee).obligations_deducted).to eq(0)
    expect(obligation_line_items(employee)).to be_empty
    expect(obligation.remaining_amount).to eq(1_500)
    expect(ObligationDeduction.where(employee_obligation: obligation)).to be_empty
  end

  it "stops deducting a cancelled obligation from the open payroll entry" do
    patch cancel_admin_employee_obligation_path(obligation)

    expect(obligation.reload).to be_cancelled
    expect(entry_for(employee).obligations_deducted).to eq(0)
    expect(obligation_line_items(employee)).to be_empty
    expect(obligation.remaining_amount).to eq(1_500)
  end

  it "deducts a resumed obligation again" do
    patch pause_admin_employee_obligation_path(obligation)
    patch resume_admin_employee_obligation_path(obligation)

    expect(obligation.reload).to be_active
    expect(entry_for(employee).obligations_deducted).to eq(500)
    expect(obligation.remaining_amount).to eq(1_000)
  end

  it "keeps the existing redirect and notice" do
    patch pause_admin_employee_obligation_path(obligation)
    expect(response).to redirect_to(admin_employee_obligation_path(obligation))
    expect(flash[:notice]).to eq(I18n.t("admin.employee_obligations.paused"))
  end

  it "leaves a finalized period's deduction unchanged" do
    period.update_column(:status, "finalized")

    patch cancel_admin_employee_obligation_path(obligation)

    expect(obligation.reload).to be_cancelled
    expect(entry_for(employee).obligations_deducted).to eq(500)
    expect(ObligationDeduction.where(employee_obligation: obligation).count).to eq(1)
  end

  it "does not change other employees' payroll" do
    expect { patch pause_admin_employee_obligation_path(obligation) }
      .not_to(change { entry_for(colleague).reload.attributes.except("updated_at") })
  end
end
