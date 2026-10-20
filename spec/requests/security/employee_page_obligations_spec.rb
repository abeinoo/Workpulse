require "rails_helper"

# The employee page's obligations card (SEC-M2-5; decisions of 2026-10-19): it
# shows obligation records and amounts only with manage_obligations and the
# employee inside the manage_obligations scope (EmployeeObligationPolicy).
# Seeing the employee page (view_employees) is not enough.
RSpec.describe "Employee page obligations card", type: :request do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }

  let(:emp_a) { create(:user, business: business).tap { |u| assign(u, branch_a) } }
  let(:emp_b) { create(:user, business: business).tap { |u| assign(u, branch_b) } }

  let!(:obligation_a) do
    create(:employee_obligation, business: business, user: emp_a, title: "Laptop loan Alpha",
                                 total_amount: 7777, remaining_amount: 6543.21, installment_amount: 432.1)
  end
  let!(:obligation_b) do
    create(:employee_obligation, business: business, user: emp_b, title: "Car loan Bravo",
                                 total_amount: 8888, remaining_amount: 5432.19, installment_amount: 321.9)
  end

  def assign(user, branch)
    create(:shift_assignment, business: business, user: user, branch: branch,
                              effective_from: 1.month.ago.to_date, effective_to: nil)
  end

  def role_user(*permissions, scopes: {})
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}",
                                              permissions: permissions.map(&:to_s), permission_scopes: scopes)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  it "shows no obligation records or amounts with view_employees alone" do
    sign_in role_user(:view_employees, scopes: { "view_employees" => "business" })
    get admin_user_path(emp_a)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Laptop loan Alpha", "6,543.21", "432.10")
  end

  it "shows them with manage_obligations for an employee inside the scope" do
    manager = role_user(:view_employees, :manage_obligations).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
    sign_in manager
    get admin_user_path(emp_a)

    expect(response.body).to include("Laptop loan Alpha", "6,543.21", "432.10")
  end

  it "hides them for an employee outside the manage_obligations scope" do
    manager = role_user(:view_employees, :manage_obligations, scopes: { "view_employees" => "business" })
    branch_a.update_column(:branch_manager_id, manager.id)
    sign_in manager
    get admin_user_path(emp_b)

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("Car loan Bravo", "5,432.19", "321.90")
  end
end
