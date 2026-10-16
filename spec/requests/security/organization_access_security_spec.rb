require "rails_helper"

# Regression coverage for the Organization & Access security findings OA-S1 to
# OA-S6 (+ cross-business branch managers, OA-S7) documented in
# docs/architecture/organization-access-migration-readiness.md.
RSpec.describe "Organization & Access security", type: :request do
  let(:business_a) { create(:business) }
  let(:business_b) { create(:business) }

  let!(:owner_a) { create(:user, :owner, business: business_a, email: "owner-a@example.com") }
  let!(:owner_b) { create(:user, :owner, business: business_b) }

  let(:full_role_a) { create(:permission_role, business: business_a, name: "Full A", permissions: PermissionRole::ALL_PERMISSIONS) }
  let(:full_role_b) { create(:permission_role, business: business_b, name: "Full B", permissions: PermissionRole::ALL_PERMISSIONS) }
  let(:cashier_role) { create(:permission_role, business: business_a, name: "Cashier", permissions: %w[view_attendance]) }

  # Admin-area access with a single low permission.
  let(:low_user) { api_user_with(business_a, :view_attendance) }
  # Explicitly business-wide employee management (OA-S8 scope), no role management.
  let(:business_scope) { { "manage_employees" => "business" } }
  let(:hr_user)  { api_user_with(business_a, :view_employees, :manage_employees, scopes: business_scope) }
  # Business-wide role + employee management, but not full access.
  let(:role_admin) do
    api_user_with(business_a, :view_employees, :manage_employees, :manage_roles, :view_attendance, scopes: business_scope)
  end
  let(:employee) { create(:user, business: business_a, email: "emp@example.com") }

  def update_user(target, attributes)
    patch admin_user_path(target), params: { user: attributes }
  end

  # ── OA-S1: self privilege escalation via parameter tampering ──────────────
  describe "OA-S1 self-modification" do
    before { sign_in low_user }

    it "ignores a self-assigned role" do
      update_user(low_user, permission_role_id: full_role_a.id)
      expect(low_user.reload.can?(:manage_settings)).to be(false)
    end

    it "ignores self-changes to administrative fields" do
      warehouse = Warehouse.create!(business: business_a, name: "WH #{SecureRandom.hex(3)}")
      update_user(low_user, active: "0", assigned_warehouse_ids: [ warehouse.id ], allow_mobile_attendance: "0",
                            admin_notes: "promoted myself", employee_code: "HACK-1")
      low_user.reload
      expect(low_user.active).to be(true)
      expect(low_user.assigned_warehouses).to be_empty
      expect(low_user.allow_mobile_attendance).to be(true)
      expect(low_user.admin_notes).to be_blank
      expect(low_user.employee_code).not_to eq("HACK-1")
    end

    it "still lets the user edit their own profile fields" do
      update_user(low_user, first_name: "Renamed")
      expect(response).to redirect_to(admin_users_path)
      expect(low_user.reload.first_name).to eq("Renamed")
    end

    it "does not offer the role, status or warehouse fields on the user's own form" do
      Warehouse.create!(business: business_a, name: "WH #{SecureRandom.hex(3)}")
      get edit_admin_user_path(low_user)
      expect(response.body).not_to include("user[permission_role_id]", "user[active]", "user[assigned_warehouse_ids]")
    end

    it "also blocks self role changes for a manage_roles holder" do
      sign_in role_admin
      original = role_admin.permission_role
      update_user(role_admin, permission_role_id: cashier_role.id)
      expect(role_admin.reload.permission_role).to eq(original)
    end
  end

  # ── OA-S2: tenant scoping ─────────────────────────────────────────────────
  describe "OA-S2 business scoping" do
    it "rejects assigning another business's role (even for the owner)" do
      sign_in owner_a
      update_user(employee, permission_role_id: full_role_b.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(employee.reload.permission_role).to be_nil
    end

    it "rejects a cross-business role at the model level (any write path)" do
      employee.permission_role = full_role_b
      expect(employee).not_to be_valid
      expect(employee.errors[:permission_role]).to be_present
    end

    it "cannot modify a user of another business (404)" do
      sign_in owner_b
      update_user(employee, first_name: "Hijacked")
      expect(response).to have_http_status(:not_found)
      expect(employee.reload.first_name).not_to eq("Hijacked")
    end

    it "cannot reset the password of a user of another business (404)" do
      sign_in owner_b
      patch admin_user_password_path(employee), params: { user: { password: "hijack1234", password_confirmation: "hijack1234" } }
      expect(response).to have_http_status(:not_found)
      expect(employee.reload.valid_password?("hijack1234")).to be(false)
    end

    it "cannot assign a role to a user of another business (404)" do
      sign_in owner_a
      post assign_user_admin_permission_role_path(cashier_role), params: { user_id: owner_b.id }
      expect(response).to have_http_status(:not_found)
      expect(owner_b.reload.permission_role).to be_nil
    end

    it "cannot open or update another business's branch (404)" do
      branch_b = create(:branch, business: business_b)
      sign_in owner_a
      patch admin_branch_path(branch_b), params: { branch: { name: "Taken" } }
      expect(response).to have_http_status(:not_found)
      expect(branch_b.reload.name).not_to eq("Taken")
    end

    it "cannot escalate through another business's full-access role via role assignment" do
      sign_in role_admin
      update_user(employee, permission_role_id: full_role_b.id)
      expect(employee.reload.permission_role).to be_nil
    end
  end

  # ── OA-S7: branch / area managers must belong to the business ─────────────
  describe "OA-S7 branch managers" do
    let(:branch_a) { create(:branch, business: business_a) }

    it "rejects a manager from another business submitted to the branch form" do
      sign_in owner_a
      patch admin_branch_path(branch_a), params: { branch: { branch_manager_id: owner_b.id, area_manager_id: owner_b.id } }
      expect(response).to have_http_status(:unprocessable_content)
      branch_a.reload
      expect(branch_a.branch_manager_id).to be_nil
      expect(branch_a.area_manager_id).to be_nil
      expect(owner_b.managed_branch_ids).not_to include(branch_a.id)
    end

    it "still accepts a manager from the same business" do
      sign_in owner_a
      patch admin_branch_path(branch_a), params: { branch: { branch_manager_id: employee.id } }
      expect(branch_a.reload.branch_manager_id).to eq(employee.id)
    end
  end

  # ── OA-S3: role assignment requires manage_roles; no escalation ───────────
  describe "OA-S3 role assignment and permission escalation" do
    it "manage_employees without manage_roles cannot assign roles (update)" do
      sign_in hr_user
      update_user(employee, permission_role_id: cashier_role.id)
      expect(employee.reload.permission_role).to be_nil
    end

    it "manage_employees without manage_roles cannot assign roles (create)" do
      sign_in hr_user
      post admin_users_path, params: { user: { first_name: "New", last_name: "Hire", email: "new@example.com",
                                               identity_card_number: "ID-NEW-12345", permission_role_id: full_role_a.id } }
      expect(User.find_by(email: "new@example.com")&.permission_role).to be_nil
    end

    it "manage_employees without manage_roles cannot use the role screens" do
      sign_in hr_user
      post assign_user_admin_permission_role_path(full_role_a), params: { user_id: employee.id }
      expect(response).to redirect_to(root_path) # require_roles_management_access!
      expect(employee.reload.permission_role).to be_nil
    end

    it "manage_roles can assign a role within their own permissions" do
      sign_in role_admin
      update_user(employee, permission_role_id: cashier_role.id)
      expect(response).to redirect_to(admin_users_path)
      expect(employee.reload.permission_role).to eq(cashier_role)
    end

    it "manage_roles can assign through the role screen within their own permissions" do
      sign_in role_admin
      post assign_user_admin_permission_role_path(cashier_role), params: { user_id: employee.id }
      expect(response).to redirect_to(admin_permission_role_path(cashier_role))
      expect(flash[:alert]).to be_nil
      expect(employee.reload.permission_role).to eq(cashier_role)
    end

    it "manage_roles cannot assign a role holding permissions they lack" do
      sign_in role_admin
      update_user(employee, permission_role_id: full_role_a.id)
      expect(response).to have_http_status(:unprocessable_content)
      expect(employee.reload.permission_role).to be_nil
    end

    it "manage_roles cannot assign a higher role through the role screen" do
      sign_in role_admin
      post assign_user_admin_permission_role_path(full_role_a), params: { user_id: employee.id }
      expect(response).to redirect_to(root_path) # PermissionRolePolicy#update? — role above the actor
      expect(employee.reload.permission_role).to be_nil
    end

    it "manage_roles cannot change the role of a more privileged user" do
      admin = create(:user, business: business_a, permission_role: full_role_a)
      sign_in role_admin
      update_user(admin, permission_role_id: cashier_role.id)
      expect(admin.reload.permission_role).to eq(full_role_a)
      delete remove_user_admin_permission_role_path(full_role_a), params: { user_id: admin.id }
      expect(response).to redirect_to(root_path)
      expect(admin.reload.permission_role).to eq(full_role_a)
    end

    it "cannot create a role with permissions the creator does not hold" do
      sign_in role_admin
      expect {
        post admin_permission_roles_path, params: { permission_role: { name: "Escalated", permissions: %w[manage_settings] } }
      }.not_to change(PermissionRole, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "cannot smuggle permissions in through role_type defaults" do
      sign_in role_admin
      expect {
        post admin_permission_roles_path, params: { permission_role: { name: "Accountant copy", role_type: "accountant" } }
      }.not_to change(PermissionRole, :count)
    end

    it "cannot add permissions it does not hold to an existing role (including its own)" do
      sign_in role_admin
      own_role = role_admin.permission_role
      patch admin_permission_role_path(own_role),
            params: { permission_role: { permissions: own_role.permissions + %w[manage_settings] } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(own_role.reload.permissions).not_to include("manage_settings")
    end

    it "cannot edit or delete a role above its own" do
      sign_in role_admin
      patch admin_permission_role_path(full_role_a), params: { permission_role: { name: "Renamed" } }
      expect(full_role_a.reload.name).to eq("Full A")
      delete admin_permission_role_path(full_role_a)
      expect(PermissionRole.exists?(full_role_a.id)).to be(true)
    end

    it "can still create a role within its own permissions" do
      sign_in role_admin
      expect {
        post admin_permission_roles_path, params: { permission_role: { name: "Viewer", permissions: %w[view_attendance] } }
      }.to change(PermissionRole, :count).by(1)
    end

    it "the owner keeps full role management" do
      sign_in owner_a
      post admin_permission_roles_path, params: { permission_role: { name: "All", permissions: PermissionRole::ALL_PERMISSIONS } }
      new_role = PermissionRole.find_by!(business: business_a, name: "All")
      update_user(employee, permission_role_id: new_role.id)
      expect(employee.reload.permission_role).to eq(new_role)
    end
  end

  # ── OA-S4 / OA-S5: the owner is a protected account ──────────────────────
  describe "OA-S4/S5 owner protection" do
    before { owner_a.update!(password: "ownerpass123", password_confirmation: "ownerpass123") }

    it "manage_employees cannot reset the owner's password" do
      sign_in hr_user
      patch admin_user_password_path(owner_a), params: { user: { password: "hijacked123", password_confirmation: "hijacked123" } }
      expect(response).to redirect_to(root_path)
      expect(owner_a.reload.valid_password?("ownerpass123")).to be(true)
    end

    it "manage_roles cannot reset the owner's password either" do
      sign_in role_admin
      patch admin_user_password_path(owner_a), params: { user: { password: "hijacked123", password_confirmation: "hijacked123" } }
      expect(owner_a.reload.valid_password?("ownerpass123")).to be(true)
    end

    it "cannot deactivate the owner through the edit form" do
      sign_in hr_user
      update_user(owner_a, active: "0")
      expect(owner_a.reload.active).to be(true)
    end

    it "cannot deactivate the owner through toggle_active (message unchanged)" do
      sign_in hr_user
      patch toggle_active_admin_user_path(owner_a)
      expect(response).to redirect_to(admin_users_path)
      expect(flash[:alert]).to eq(I18n.t("flash.cannot_deactivate_owner"))
      expect(owner_a.reload.active).to be(true)
    end

    it "cannot delete the owner" do
      sign_in hr_user
      delete admin_user_path(owner_a)
      expect(response).to redirect_to(root_path)
      expect(User.exists?(owner_a.id)).to be(true)
    end

    it "cannot change the owner's login identifiers or role through employee management" do
      sign_in role_admin
      update_user(owner_a, email: "attacker@example.com", permission_role_id: cashier_role.id)
      owner_a.reload
      expect(owner_a.email).to eq("owner-a@example.com")
      expect(owner_a.permission_role).to be_nil
    end

    it "cannot remove or change the owner's role through the role screens" do
      owner_a.update_column(:permission_role_id, cashier_role.id)
      sign_in role_admin
      delete remove_user_admin_permission_role_path(cashier_role), params: { user_id: owner_a.id }
      expect(response).to redirect_to(admin_permission_role_path(cashier_role))
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(owner_a.reload.permission_role).to eq(cashier_role)
    end

    it "still lets HR reset a regular employee's password (audited)" do
      sign_in hr_user
      expect {
        patch admin_user_password_path(employee), params: { user: { password: "newpass1234", password_confirmation: "newpass1234" } }
      }.to change(UserAuditLog, :count).by(1)
      expect(employee.reload.valid_password?("newpass1234")).to be(true)
    end

    it "still lets the owner transfer ownership" do
      sign_in owner_a
      patch transfer_ownership_admin_user_path(employee)
      expect(business_a.reload.owner_id).to eq(employee.id)
    end
  end

  # ── OA-S6: account claim needs the invitation link ───────────────────────
  describe "OA-S6 account claim" do
    let!(:pending) { create(:user, :phone_only, :unregistered, business: business_a, phone_number: "+966507777777") }

    def claim(login:, token: nil, password: "claim12345")
      post user_registration_path,
           params: { user: { login: login, password: password, password_confirmation: password, invitation_token: token } }
    end

    it "refuses a claim with only the phone number (no sign-in, no password set)" do
      claim(login: "+966507777777")
      expect(response).to have_http_status(:unprocessable_content)
      expect(pending.reload.encrypted_password).to be_blank
      get root_path
      expect(response).to redirect_to(new_user_session_path)
    end

    it "refuses a claim with another employee's invitation link" do
      other = create(:user, :phone_only, :unregistered, business: business_a)
      claim(login: "+966507777777", token: other.generate_token_for(:account_claim))
      expect(pending.reload.encrypted_password).to be_blank
    end

    it "gives the same answer for unknown, unclaimed and registered accounts (no enumeration)" do
      { nil => "auth.register.invitation_required", "forged--token" => "auth.register.invalid_invitation" }.each do |token, key|
        expected = ERB::Util.html_escape(I18n.t(key))
        [ "+966500000001", "+966507777777", owner_a.email ].each do |login|
          claim(login: login, token: token)
          expect(response).to have_http_status(:unprocessable_content)
          expect(response.body).to include(expected)
          expect(response.body).not_to include("No account found", "already been registered")
        end
      end
    end

    it "activates the account through the administrator's invitation link" do
      token = pending.generate_token_for(:account_claim)
      get new_user_registration_path(invitation: token)
      expect(response.body).to include(token)

      claim(login: "+966507777777", token: token)
      expect(response).to redirect_to(root_path)
      expect(pending.reload.valid_password?("claim12345")).to be(true)
    end

    it "shows the invitation link only to employee managers, only for pending accounts" do
      sign_in hr_user
      get admin_user_path(pending)
      expect(response.body).to include(I18n.t("admin.users.invitation_link"))

      get admin_user_path(employee)
      expect(response.body).not_to include(I18n.t("admin.users.invitation_link"))
    end

    it "does not show the invitation link to a user without manage_employees" do
      viewer = api_user_with(business_a, :view_employees)
      sign_in viewer
      get admin_user_path(pending)
      expect(response.body).not_to include(I18n.t("admin.users.invitation_link"))
    end
  end
end
