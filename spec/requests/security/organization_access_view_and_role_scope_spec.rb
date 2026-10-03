require "rails_helper"

# Regression coverage for the last two Organization & Access concerns
# (docs/architecture/organization-access-migration-readiness.md):
#   * employee profile visibility follows the employee scope (direct URL / IDOR)
#   * role administrators cannot grant a permission at a broader scope than
#     their own (narrow guard — not a full permission-scope model)
RSpec.describe "Organization & Access — profile visibility and role scope escalation", type: :request do
  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  let!(:owner)         { create(:user, :owner, business: business) }

  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:morning)  { create(:shift, :fixed_time, business: business, start_time: "09:00", end_time: "13:00") }
  let(:evening)  { create(:shift, :fixed_time, business: business, start_time: "14:00", end_time: "18:00") }

  def employee_at(*branches)
    create(:user, business: business, first_name: "Emp#{SecureRandom.hex(2)}").tap do |user|
      branches.zip([ morning, evening ]).each do |branch, shift|
        create(:shift_assignment, user: user, branch: branch, shift: shift)
      end
    end
  end

  let(:emp_a)  { employee_at(branch_a) }
  let(:emp_b)  { employee_at(branch_b) }
  let(:emp_ab) { employee_at(branch_a, branch_b) }

  # ── Employee profile visibility (direct URL) ─────────────────────────────
  describe "employee profile visibility" do
    let(:branch_viewer) do
      api_user_with(business, :view_employees).tap { |u| branch_a.update_column(:branch_manager_id, u.id) }
    end

    it "1. branch manager → same-branch employee: allowed" do
      sign_in branch_viewer
      get admin_user_path(emp_a)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(emp_a.first_name)
    end

    it "2. branch manager → different-branch employee: denied, nothing disclosed" do
      sign_in branch_viewer
      get admin_user_path(emp_b)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(response.body).not_to include(emp_b.first_name)
    end

    it "3. business-wide view_employees → any employee of the business: allowed" do
      sign_in api_user_with(business, :view_employees, scopes: { "view_employees" => "business" })
      get admin_user_path(emp_b)
      expect(response).to have_http_status(:ok)
    end

    it "4. any user → employee of another business: not found (even the owner)" do
      foreign = create(:user, business: other_business)
      sign_in owner
      get admin_user_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "5. multi-branch employee → manager of an assigned branch: allowed" do
      sign_in branch_viewer
      get admin_user_path(emp_ab)
      expect(response).to have_http_status(:ok)
    end

    it "an employee the actor may manage is also visible to them" do
      sign_in api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" })
      get admin_user_path(emp_b)
      expect(response).to have_http_status(:ok)
    end

    # (A plain employee has no admin-area access at all — unchanged gate.)
    it "a plain employee cannot open another employee's profile" do
      sign_in emp_a
      get admin_user_path(emp_b)
      expect(response).to redirect_to(root_path)
      expect(response.body).not_to include(emp_b.first_name)
    end
  end

  # ── Role scope escalation ────────────────────────────────────────────────
  describe "role permission scope" do
    def role_admin_with(scope)
      api_user_with(business, :view_employees, :manage_employees, :manage_roles,
                    scopes: { "manage_employees" => scope }).tap do |u|
        branch_a.update_column(:branch_manager_id, u.id) if scope == "branch"
      end
    end

    let(:branch_role_admin)   { role_admin_with("branch") }
    let(:business_role_admin) { role_admin_with("business") }

    def create_role(name, scopes)
      post admin_permission_roles_path, params: {
        permission_role: { name: name, permissions: %w[view_employees manage_employees], permission_scopes: scopes }
      }
    end

    def role_granting(scope, business: self.business)
      create(:permission_role, business: business, permissions: %w[view_employees manage_employees],
                               permission_scopes: { "manage_employees" => scope })
    end

    it "6. branch-scoped role admin → branch-scoped role: allowed" do
      sign_in branch_role_admin
      expect { create_role("Branch HR", { "manage_employees" => "branch" }) }.to change(PermissionRole, :count).by(1)
      expect(PermissionRole.find_by!(name: "Branch HR").scope_for(:manage_employees)).to eq("branch")
    end

    describe "7. branch-scoped role admin → business-scoped permission: denied" do
      before { sign_in branch_role_admin }

      it "when creating a role" do
        expect { create_role("Business HR", { "manage_employees" => "business" }) }.not_to change(PermissionRole, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "when widening an existing role's scope" do
        role = role_granting("branch")
        patch admin_permission_role_path(role), params: {
          permission_role: { permissions: role.permissions, permission_scopes: { "manage_employees" => "business" } }
        }
        expect(response).to have_http_status(:unprocessable_content)
        expect(role.reload.scope_for(:manage_employees)).to eq("branch")
      end

      it "when leaving the scope blank (hierarchy default spans managed areas, broader than branch)" do
        expect { create_role("Default HR", {}) }.not_to change(PermissionRole, :count)
      end

      it "when editing or deleting a business-scoped role" do
        role = role_granting("business")
        patch admin_permission_role_path(role), params: { permission_role: { name: "Renamed" } }
        expect(role.reload.name).not_to eq("Renamed")
        delete admin_permission_role_path(role)
        expect(PermissionRole.exists?(role.id)).to be(true)
      end

      it "when assigning an existing business-scoped role (role screen and employee form)" do
        role = role_granting("business")
        target = employee_at(branch_a)

        post assign_user_admin_permission_role_path(role), params: { user_id: target.id }
        expect(response).to redirect_to(root_path)
        expect(target.reload.permission_role).to be_nil

        patch admin_user_path(target), params: { user: { permission_role_id: role.id } }
        expect(target.reload.permission_role).to be_nil
      end
    end

    it "8. business-scoped role admin → business-scoped permission: allowed (create and assign)" do
      sign_in business_role_admin
      expect { create_role("Business HR", { "manage_employees" => "business" }) }.to change(PermissionRole, :count).by(1)

      role = PermissionRole.find_by!(name: "Business HR")
      target = employee_at(branch_b)
      post assign_user_admin_permission_role_path(role), params: { user_id: target.id }
      expect(target.reload.permission_role).to eq(role)
    end

    describe "9. cross-business role manipulation: denied" do
      let(:foreign_role) { role_granting("branch", business: other_business) }

      it "cannot edit, delete or assign another business's role (404)" do
        sign_in business_role_admin
        patch admin_permission_role_path(foreign_role), params: { permission_role: { name: "Taken" } }
        expect(response).to have_http_status(:not_found)

        sign_in business_role_admin
        post assign_user_admin_permission_role_path(foreign_role), params: { user_id: emp_a.id }
        expect(response).to have_http_status(:not_found)
        expect(foreign_role.reload.name).not_to eq("Taken")
      end

      it "cannot assign another business's role through the employee form" do
        sign_in business_role_admin
        patch admin_user_path(emp_a), params: { user: { permission_role_id: foreign_role.id } }
        expect(emp_a.reload.permission_role).to be_nil
      end
    end

    it "the owner keeps full capabilities" do
      sign_in owner
      expect { create_role("Any scope", { "manage_employees" => "business" }) }.to change(PermissionRole, :count).by(1)
    end
  end
end
