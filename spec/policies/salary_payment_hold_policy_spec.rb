require "rails_helper"

# SalaryPaymentHoldPolicy — holds are seen and managed only within the payroll
# the actor already sees, never one's own, never across businesses.
RSpec.describe SalaryPaymentHoldPolicy do
  let(:business) { create(:business) }
  let(:north)    { create(:branch, business: business) }
  let(:south)    { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:north_employee) { employee_at(north) }
  let(:south_employee) { employee_at(south) }

  def employee_at(branch)
    create(:user, business: business).tap do |u|
      create(:shift_assignment, user: u, branch: branch, shift: shift, effective_from: Date.new(2026, 1, 1))
    end
  end

  def role_user(permissions, scopes: {}, manages: nil)
    role = business.permission_roles.create!(name: "R#{SecureRandom.hex(3)}", permissions: permissions, permission_scopes: scopes)
    create(:user, business: business, permission_role: role).tap { |u| manages&.update_column(:branch_manager_id, u.id) }
  end

  def probe(user) = SalaryPaymentHold.new(business_id: user.business_id, user_id: user.id)
  def policy(actor, record) = described_class.new(actor, record)

  let(:hr) do
    role_user(%w[view_payroll view_salary_payment_holds manage_salary_payment_holds],
              scopes: %w[view_payroll view_salary_payment_holds manage_salary_payment_holds].to_h { [ _1, "business" ] })
  end
  let(:finance) do
    role_user(%w[view_payroll view_salary_payment_holds],
              scopes: { "view_payroll" => "business", "view_salary_payment_holds" => "business" })
  end

  it "lets HR view, place and release holds for employees in scope" do
    expect(policy(hr, probe(north_employee))).to have_attributes(show?: true, create?: true)
    hold = create(:salary_payment_hold, user: north_employee, created_by: hr)
    expect(policy(hr, hold).release?).to be(true)
  end

  it "lets finance view holds but never place or release them" do
    hold = create(:salary_payment_hold, user: north_employee, created_by: hr)
    expect(policy(finance, hold)).to have_attributes(show?: true, create?: false, release?: false)
  end

  it "gives view_payroll alone (no hold permission) nothing" do
    payroll_only = role_user(%w[view_payroll], scopes: { "view_payroll" => "business" })
    expect(policy(payroll_only, probe(north_employee))).to have_attributes(show?: false, create?: false)
  end

  it "gives a cashier / plain employee nothing" do
    cashier = create(:user, business: business)
    expect(policy(cashier, probe(north_employee))).to have_attributes(show?: false, create?: false)
  end

  it "limits a branch manager to their branch's employees" do
    manager = role_user(%w[view_payroll view_salary_payment_holds],
                        scopes: { "view_payroll" => "branch", "view_salary_payment_holds" => "branch" }, manages: north)
    expect(policy(manager, probe(north_employee)).show?).to be(true)
    expect(policy(manager, probe(south_employee)).show?).to be(false)
    expect(policy(manager, probe(north_employee)).create?).to be(false)
  end

  it "never reaches beyond the actor's payroll visibility" do
    narrow = role_user(%w[view_payroll view_salary_payment_holds manage_salary_payment_holds],
                       scopes: { "view_payroll" => "branch", "view_salary_payment_holds" => "business",
                                 "manage_salary_payment_holds" => "business" }, manages: north)
    expect(policy(narrow, probe(south_employee))).to have_attributes(show?: false, create?: false)
  end

  it "never lets anyone act on their own hold — the owner included" do
    owner = create(:user, :owner, business: business)
    expect(policy(hr, probe(hr))).to have_attributes(show?: false, create?: false)
    expect(policy(owner, probe(owner))).to have_attributes(show?: false, create?: false)
    expect(policy(owner, probe(north_employee))).to have_attributes(show?: true, create?: true)
  end

  it "refuses another business's hold, whatever the permissions" do
    outsider_hold = create(:salary_payment_hold)
    expect(policy(hr, outsider_hold)).to have_attributes(show?: false, create?: false, release?: false)
  end

  it "refuses releasing a released hold" do
    hold = create(:salary_payment_hold, user: north_employee, created_by: hr, released_at: Time.current, released_by: hr)
    expect(policy(hr, hold).release?).to be(false)
  end

  it "requires the dependencies: manage needs view, view needs view_payroll" do
    expect(PermissionRole::PERMISSION_DEPENDENCIES).to include(
      "view_salary_payment_holds" => %w[view_payroll], "manage_salary_payment_holds" => %w[view_salary_payment_holds]
    )
    role = business.permission_roles.new(name: "bad", permissions: %w[manage_salary_payment_holds])
    expect(role).not_to be_valid
  end
end
