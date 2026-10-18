require "rails_helper"

# Characterization — permission role administration (CURRENT behaviour) for the
# normal (owner / business-wide administrator) path. Escalation, scope and
# hierarchy limits are covered by spec/requests/security/organization_access_*.
RSpec.describe "Characterization: Organization & Access permission roles", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }

  before { sign_in owner }

  def role_params(**overrides)
    { name: "Supervisors", description: "Shift supervisors", workspace: "management",
      permissions: %w[view_attendance view_shifts], permission_scopes: {} }.merge(overrides)
  end

  describe "index / show" do
    it "lists only the business's roles" do
      own   = create(:permission_role, business: business, name: "Own role")
      other = create(:permission_role, name: "Foreign role")
      get admin_permission_roles_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(own.name)
      expect(response.body).not_to include(other.name)
    end

    it "show lists assigned users and offers only unassigned/same-role users, never the owner" do
      role       = create(:permission_role, business: business, name: "Cashiers")
      member     = create(:user, business: business, permission_role: role, first_name: "Member")
      unassigned = create(:user, business: business, first_name: "Unassigned")
      elsewhere  = create(:user, business: business, first_name: "Elsewhere",
                                 permission_role: create(:permission_role, business: business))
      get admin_permission_role_path(role)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(html_escaped(member.full_name), html_escaped(unassigned.full_name))
      expect(response.body).not_to include(html_escaped(elsewhere.full_name))
    end
  end

  describe "create" do
    it "creates a role in the actor's business and redirects to it" do
      expect { post admin_permission_roles_path, params: { permission_role: role_params } }
        .to change { business.permission_roles.count }.by(1)
      role = business.permission_roles.find_by!(name: "Supervisors")
      expect(response).to redirect_to(admin_permission_role_path(role))
      expect(role.permissions).to match_array(%w[view_attendance view_shifts])
    end

    it "fills default permissions from role_type when none are chosen" do
      post admin_permission_roles_path, params: { permission_role: role_params(name: "Managers", role_type: "branch_manager", permissions: [ "" ]) }
      role = business.permission_roles.find_by!(name: "Managers")
      expect(role.permissions).to match_array(PermissionRole::DEFAULT_PERMISSIONS_BY_ROLE_TYPE["branch_manager"])
    end

    # KNOWN DEFECT (existing behaviour): the built-in "accountant" default set
    # includes view_sales_transactions_verification without its dependency
    # view_daily_reconciliation, so a role created from those defaults always
    # fails validation. (branch_manager, area_manager and employee defaults are valid.)
    it "cannot create an accountant role from its defaults (known defect)" do
      expect {
        post admin_permission_roles_path, params: { permission_role: role_params(name: "Accounting", role_type: "accountant", permissions: [ "" ]) }
      }.not_to change(PermissionRole, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a permission whose dependency is missing (422, nothing saved)" do
      expect {
        post admin_permission_roles_path, params: { permission_role: role_params(name: "Broken", permissions: %w[manage_attendance]) }
      }.not_to change(PermissionRole, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rejects a duplicate name within the business" do
      create(:permission_role, business: business, name: "Supervisors")
      post admin_permission_roles_path, params: { permission_role: role_params }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "stores per-permission scopes, normalized and limited to granted permissions" do
      post admin_permission_roles_path, params: {
        permission_role: role_params(name: "Scoped", permissions: %w[view_attendance],
                                     permission_scopes: { "view_attendance" => "branch", "view_payroll" => "business" })
      }
      role = business.permission_roles.find_by!(name: "Scoped")
      expect(role.permission_scopes).to eq("view_attendance" => "branch")
    end
  end

  describe "update" do
    it "updates the role and its effective permissions for every holder" do
      role = create(:permission_role, business: business, permissions: %w[view_attendance])
      employee.update!(permission_role: role)
      patch admin_permission_role_path(role), params: { permission_role: { permissions: %w[view_attendance view_shifts] } }
      expect(response).to redirect_to(admin_permission_role_path(role))
      expect(employee.reload.can?(:view_shifts)).to be(true)
    end
  end

  describe "destroy" do
    it "deletes a role with no users" do
      role = create(:permission_role, business: business)
      delete admin_permission_role_path(role)
      expect(response).to redirect_to(admin_permission_roles_path)
      expect(PermissionRole.exists?(role.id)).to be(false)
    end

    it "refuses to delete a role that still has users" do
      role = create(:permission_role, business: business)
      employee.update!(permission_role: role)
      delete admin_permission_role_path(role)
      expect(flash[:alert]).to eq(I18n.t("flash.permission_role_has_users"))
      expect(PermissionRole.exists?(role.id)).to be(true)
    end
  end

  describe "assign / remove user" do
    let(:role) { create(:permission_role, business: business, permissions: %w[view_attendance]) }

    it "assigns and removes a role; the user's effective permissions follow" do
      post assign_user_admin_permission_role_path(role), params: { user_id: employee.id }
      expect(response).to redirect_to(admin_permission_role_path(role))
      expect(employee.reload.can?(:view_attendance)).to be(true)

      delete remove_user_admin_permission_role_path(role), params: { user_id: employee.id }
      expect(employee.reload.permission_role).to be_nil
      expect(employee.can?(:view_attendance)).to be(false)
    end

    it "is NOT audited (existing behaviour — role changes leave no audit record)" do
      expect {
        post assign_user_admin_permission_role_path(role), params: { user_id: employee.id }
      }.not_to change { [ AuditLog.count, UserAuditLog.count ] }
    end
  end

  describe "effective permissions (owner)" do
    it "the owner holds every permission without any role" do
      expect(owner.permission_role).to be_nil
      expect(PermissionRole::ALL_PERMISSIONS.all? { |p| owner.can?(p) }).to be(true)
    end
  end
end
