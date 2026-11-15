require "rails_helper"

# Employee Data Export permissions: export_employees (needs view_employees) and
# export_employee_identity (needs export_employees) — in no default role.
RSpec.describe UserPolicy, "employee export" do
  let(:business) { create(:business) }

  def user_with(*permissions)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s))
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def policy(user) = described_class.new(user, User)

  it "allows export only with export_employees and the Employees page" do
    expect(policy(user_with(:view_employees)).export?).to be false
    expect(policy(user_with(:view_employees, :manage_employees)).export?).to be false
    expect(policy(user_with(:view_employees, :export_employees)).export?).to be true
    expect(policy(create(:user, business: business)).export?).to be false
  end

  it "allows National ID only with export_employee_identity on top" do
    expect(policy(user_with(:view_employees, :export_employees)).export_identity?).to be false
    expect(policy(user_with(:view_employees, :export_employees, :export_employee_identity)).export_identity?).to be true
  end

  it "lets the owner export everything" do
    owner = create(:user, :owner, business: business)
    expect(policy(owner).export?).to be true
    expect(policy(owner).export_identity?).to be true
  end

  describe "the permission catalogue" do
    it "lists both permissions in the employees group with their dependencies" do
      expect(PermissionRole::PERMISSION_GROUPS[:employees]).to include("export_employees", "export_employee_identity")
      expect(PermissionRole::PERMISSION_DEPENDENCIES["export_employees"]).to eq(%w[view_employees])
      expect(PermissionRole::PERMISSION_DEPENDENCIES["export_employee_identity"]).to eq(%w[export_employees])
    end

    it "refuses a role holding either permission without its dependency" do
      role = business.permission_roles.build(name: "Bad", permissions: %w[export_employees])
      expect(role).not_to be_valid
      role.permissions = %w[view_employees export_employee_identity]
      expect(role).not_to be_valid
    end

    it "grants neither permission by default and does not scope them" do
      PermissionRole::DEFAULT_PERMISSIONS_BY_ROLE_TYPE.each_value do |permissions|
        expect(permissions).not_to include("export_employees", "export_employee_identity")
      end
      expect(PermissionRole::SCOPABLE_PERMISSIONS).not_to include("export_employees", "export_employee_identity")
    end
  end

  describe "the fields offered (Employee::Export::FieldCatalog)" do
    def keys(*permissions) = Employee::Export::FieldCatalog.permitted_keys(user_with(*permissions))

    it "offers nothing without export_employees" do
      expect(keys(:view_employees, :view_payroll, :view_employee_insurance, :manage_employee_insurance)).to be_empty
    end

    it "offers sensitive fields only with their own permission" do
      base = keys(:view_employees, :export_employees)
      expect(base).to include("full_name", "email", "branch", "notes")
      expect(base).not_to include("national_id", "basic_salary", "salary_type", "social_insurance_number",
                                  "social_insurance_employer_contribution")

      expect(keys(:view_employees, :export_employees, :export_employee_identity)).to include("national_id")
      expect(keys(:view_employees, :export_employees, :view_payroll)).to include("basic_salary", "salary_type")
      insurance_viewer = keys(:view_employees, :export_employees, :view_employee_insurance)
      expect(insurance_viewer).to include("social_insurance_number")
      expect(insurance_viewer).not_to include("social_insurance_employer_contribution")
      expect(keys(:view_employees, :export_employees, :view_employee_insurance, :manage_employee_insurance))
        .to include("social_insurance_employer_contribution")
    end

    it "lists no field for data WorkPulse does not store" do
      expect(Employee::Export::FieldCatalog::BY_KEY.keys)
        .not_to include("gender", "marital_status", "bank_account_number", "transportation_allowance",
                        "educational_qualification")
    end
  end
end
