require "rails_helper"

# Step 5 (R-H2): the role screen (POST assign_user / DELETE remove_user) and the
# employee form (PATCH admin/users/:id) both decide through
# OrganizationAccess::RoleAssignmentRule. For every scenario both entry points
# must reach the same outcome on the target's role.
RSpec.describe "Role assignment entry points parity", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:actor) do
    api_user_with(business, :view_attendance, :view_shifts, :view_employees, :manage_employees, :manage_roles,
                  scopes: { "view_attendance" => "branch", "manage_employees" => "business", "view_employees" => "business" })
  end
  let(:within)        { create(:permission_role, business: business, permissions: %w[view_attendance], permission_scopes: { "view_attendance" => "branch" }) }
  let(:above)         { create(:permission_role, business: business, permissions: %w[view_attendance view_payroll]) }
  let(:broader_scope) { create(:permission_role, business: business, permissions: %w[view_attendance], permission_scopes: { "view_attendance" => "business" }) }

  def via_role_screen(target, role)
    sign_in actor
    post assign_user_admin_permission_role_path(role), params: { user_id: target.id }
    target.reload.permission_role_id
  end

  def via_employee_form(target, role)
    sign_in actor
    patch admin_user_path(target), params: { user: { first_name: target.first_name, permission_role_id: role.id } }
    target.reload.permission_role_id
  end

  def outcomes(role, target_factory)
    [ via_role_screen(target_factory.call, role), via_employee_form(target_factory.call, role) ]
  end

  let(:fresh_employee) { -> { create(:user, business: business) } }

  it "a role within the actor's authority: assigned by both" do
    expect(outcomes(within, fresh_employee)).to eq([ within.id, within.id ])
  end

  it "a role with a permission the actor lacks: refused by both" do
    expect(outcomes(above, fresh_employee)).to eq([ nil, nil ])
  end

  it "a role with a scope broader than the actor's: refused by both" do
    expect(outcomes(broader_scope, fresh_employee)).to eq([ nil, nil ])
  end

  it "moving a user off a role above the actor: refused by both" do
    holder = -> { create(:user, business: business, permission_role: above) }
    expect(outcomes(within, holder)).to eq([ above.id, above.id ])
  end

  it "the owner as target: refused by both" do
    expect(outcomes(within, -> { owner })).to eq([ nil, nil ])
  end

  it "the actor themselves: refused by both" do
    original = actor.permission_role_id
    expect(outcomes(within, -> { actor })).to eq([ original, original ])
  end

  it "a role of another business: never assigned by either (role screen 404, form refusal)" do
    foreign = create(:permission_role, business: create(:business), permissions: %w[view_attendance])
    target  = create(:user, business: business)

    sign_in actor
    post assign_user_admin_permission_role_path(foreign), params: { user_id: target.id }
    expect(response).to have_http_status(:not_found)
    expect(via_employee_form(target, foreign)).to be_nil
  end
end
