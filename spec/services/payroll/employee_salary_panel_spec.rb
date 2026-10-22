require "rails_helper"

# SAL — Payroll::EmployeeSalaryPanel through the contract: visibility, the
# current profile, the audit, business isolation. Markup is pinned by the golden
# files of spec/characterization/workforce/employee_salary_panel_spec.rb.
RSpec.describe Payroll::EmployeeSalaryPanel do
  let(:contract) { Employee::ProfilePanels }
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) do
    create(:user, business: business).tap do |u|
      create(:shift_assignment, business: business, user: u, branch: branch, effective_from: 1.month.ago.to_date)
    end
  end
  let!(:current) { create(:salary_profile, user: employee, base_amount: 4321.98, effective_from: 1.year.ago.to_date) }

  def manager(*permissions)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      branch.update_column(:branch_manager_id, u.id)
    end
  end

  def views = AuditLog.where(action: "view_salary")

  it "returns nil and audits nothing for a viewer who may neither see nor manage the salary" do
    viewer = manager(:view_employees)
    expect { expect(contract.salary_panel(viewer: viewer, employee: employee)).to be_nil }.not_to change(views, :count)
  end

  it "returns the AP partial with the current profile and records one view" do
    viewer = manager(:view_employees, :view_payroll)
    panel = nil
    expect { panel = contract.salary_panel(viewer: viewer, employee: employee) }.to change(views, :count).by(1)
    expect(panel.partial).to eq("admin/salary_profiles/employee_panel")
    expect(panel.locals).to eq(employee: employee, salary_visible: true, salary_manageable: false, profile: current)
  end

  it "manage only: a panel without a profile and no audit" do
    viewer = manager(:view_employees, :manage_salary_profiles)
    panel = nil
    expect { panel = contract.salary_panel(viewer: viewer, employee: employee) }.not_to change(views, :count)
    expect(panel.locals).to include(salary_visible: false, salary_manageable: true, profile: nil)
  end

  it "never shows another business's employee" do
    other = create(:user, business: create(:business))
    create(:salary_profile, user: other, base_amount: 1, effective_from: 1.year.ago.to_date)
    panel = contract.salary_panel(viewer: manager(:view_employees, :view_payroll), employee: other)
    expect(panel&.locals&.fetch(:profile)).to be_nil
  end
end
