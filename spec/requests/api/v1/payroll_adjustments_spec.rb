require "rails_helper"

# Confirms the adjustments API collection is scope-aware: an employee may load it
# (for a period they can see — finalized/paid with their own entry) and receives
# ONLY their own approved adjustments, never pending ones or other employees'.
RSpec.describe "API::V1 PayrollAdjustments index", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:manager)  { create(:user, :branch_manager, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:coworker) { create(:user, business: business) }

  # Employees can only load finalized/paid periods in which they have an entry
  # (PayrollPeriodPolicy::Scope), so use a paid period with the employee's entry.
  let!(:period) { create(:payroll_period, :paid, business: business) }
  let!(:entry)  { create(:payroll_entry, payroll_period: period, user: employee) }

  let!(:my_approved) do
    create(:payroll_adjustment, :cash_incentive, :approved, business: business,
           user: employee, created_by: manager, payroll_period: period,
           period_month: period.period_month, period_year: period.period_year)
  end
  # Legacy state: a pending adjustment can no longer be created in a paid
  # period, so it is created approved and set back to pending.
  let!(:my_pending) do
    create(:payroll_adjustment, :commission, :approved, business: business,
           user: employee, created_by: manager, payroll_period: period,
           period_month: period.period_month, period_year: period.period_year)
      .tap { |adj| adj.update_column(:review_status, "pending_review") }
  end
  let!(:coworker_approved) do
    create(:payroll_adjustment, :cash_incentive, :approved, business: business,
           user: coworker, created_by: manager, payroll_period: period,
           period_month: period.period_month, period_year: period.period_year)
  end

  it "returns only the employee's own approved adjustments" do
    sign_in employee
    get api_v1_payroll_period_payroll_adjustments_path(period)

    expect(response).to have_http_status(:ok)
    ids = JSON.parse(response.body).fetch("data").map { |a| a["id"] }
    expect(ids).to contain_exactly(my_approved.id)
    expect(ids).not_to include(my_pending.id, coworker_approved.id)
  end
end
