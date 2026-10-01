require "rails_helper"

# Regression coverage for OA-S8 (employee-management scope) and the privilege
# hierarchy (docs/architecture/organization-access-migration-readiness.md).
# Every decision is server-side: actor + permission + business + branch scope +
# the target's administrative authority.
RSpec.describe "Organization & Access — employee-management scope and privilege hierarchy", type: :request do
  let(:business)       { create(:business) }
  let(:other_business) { create(:business) }
  let!(:owner)         { create(:user, :owner, business: business) }

  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:morning)  { create(:shift, :fixed_time, business: business, start_time: "09:00", end_time: "13:00") }
  let(:evening)  { create(:shift, :fixed_time, business: business, start_time: "14:00", end_time: "18:00") }

  def employee_at(*branches, **attributes)
    user = create(:user, business: business, **attributes)
    branches.zip([ morning, evening ]).each do |branch, shift|
      create(:shift_assignment, user: user, branch: branch, shift: shift)
    end
    user
  end

  def role_with(*permissions)
    create(:permission_role, business: business, permissions: permissions.map(&:to_s))
  end

  let(:emp_a)  { employee_at(branch_a) }
  let(:emp_b)  { employee_at(branch_b) }
  let(:emp_ab) { employee_at(branch_a, branch_b) }

  # Branch-scoped employee manager of branch A (configured "branch" scope).
  let(:branch_manager) do
    api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "branch" }).tap do |u|
      branch_a.update_column(:branch_manager_id, u.id)
    end
  end
  # Explicitly business-wide employee manager.
  let(:business_manager) do
    api_user_with(business, :view_employees, :manage_employees, scopes: { "manage_employees" => "business" })
  end

  def edit(target, attributes)
    patch admin_user_path(target), params: { user: attributes }
  end

  def reset_password(target, password = "newpass1234")
    patch admin_user_password_path(target), params: { user: { password: password, password_confirmation: password } }
  end

  # ── OA-S8: branch-scoped employee management ─────────────────────────────
  describe "OA-S8 scope" do
    context "Branch A manager → Branch A employee" do
      before { sign_in branch_manager }

      it "may edit, reset the password and deactivate" do
        edit(emp_a, first_name: "Allowed")
        expect(emp_a.reload.first_name).to eq("Allowed")

        reset_password(emp_a)
        expect(emp_a.reload.valid_password?("newpass1234")).to be(true)

        patch toggle_active_admin_user_path(emp_a)
        expect(emp_a.reload.active).to be(false)
      end
    end

    context "Branch A manager → Branch B employee" do
      before { sign_in branch_manager }

      it "cannot edit the employee's information" do
        edit(emp_b, first_name: "Changed", phone_number: "+966508888888")
        expect(response).to redirect_to(root_path)
        expect(emp_b.reload.first_name).not_to eq("Changed")
      end

      it "cannot reset the employee's credentials" do
        reset_password(emp_b)
        expect(response).to redirect_to(root_path)
        expect(emp_b.reload.valid_password?("newpass1234")).to be(false)
      end

      it "cannot deactivate the employee" do
        patch toggle_active_admin_user_path(emp_b)
        expect(response).to redirect_to(root_path)
        expect(emp_b.reload.active).to be(true)
      end

      it "cannot modify the employee's access" do
        warehouse = Warehouse.create!(business: business, name: "WH #{SecureRandom.hex(3)}")
        edit(emp_b, active: "0", assigned_warehouse_ids: [ warehouse.id ])
        emp_b.reload
        expect(emp_b.active).to be(true)
        expect(emp_b.assigned_warehouses).to be_empty
      end

      it "cannot delete the employee" do
        delete admin_user_path(emp_b)
        expect(User.exists?(emp_b.id)).to be(true)
      end

      it "is not shown the employee's invitation link" do
        pending_b = employee_at(branch_b)
        pending_b.update_column(:encrypted_password, "")
        get admin_user_path(pending_b)
        expect(response.body).not_to include(I18n.t("admin.users.invitation_link"))
      end
    end

    context "Branch A manager → employee assigned to Branch A and Branch B" do
      # Membership is shift-driven: an employee currently working at Branch A is
      # a Branch A employee for its manager, even if they also work elsewhere.
      it "may manage them because they are currently assigned to Branch A" do
        sign_in branch_manager
        edit(emp_ab, first_name: "Shared")
        expect(emp_ab.reload.first_name).to eq("Shared")
        reset_password(emp_ab)
        expect(emp_ab.reload.valid_password?("newpass1234")).to be(true)
      end

      it "loses that ability when the Branch A assignment ends" do
        emp_ab.shift_assignments.find_by(branch: branch_a).update_column(:effective_to, Date.yesterday)
        sign_in branch_manager
        reset_password(emp_ab)
        expect(emp_ab.reload.valid_password?("newpass1234")).to be(false)
      end
    end

    context "branch manager without a configured scope (management hierarchy default)" do
      let(:hierarchy_manager) do
        api_user_with(business, :view_employees, :manage_employees).tap do |u|
          branch_a.update_column(:branch_manager_id, u.id)
        end
      end

      it "manages Branch A but not Branch B" do
        sign_in hierarchy_manager
        edit(emp_a, first_name: "Yes")
        edit(emp_b, first_name: "No")
        expect(emp_a.reload.first_name).to eq("Yes")
        expect(emp_b.reload.first_name).not_to eq("No")
      end
    end

    context "business-wide manager → Branch B employee" do
      it "may manage the employee" do
        sign_in business_manager
        edit(emp_b, first_name: "BusinessWide")
        expect(emp_b.reload.first_name).to eq("BusinessWide")
        reset_password(emp_b)
        expect(emp_b.reload.valid_password?("newpass1234")).to be(true)
        patch toggle_active_admin_user_path(emp_b)
        expect(emp_b.reload.active).to be(false)
      end

      it "may also manage employees with no branch assignment" do
        unassigned = create(:user, business: business)
        sign_in business_manager
        edit(unassigned, first_name: "Reached")
        expect(unassigned.reload.first_name).to eq("Reached")
      end
    end

    context "cross-business" do
      it "cannot reach an employee of another business (404) even with business-wide scope" do
        foreign = create(:user, business: other_business)
        sign_in business_manager
        edit(foreign, first_name: "Foreign")
        expect(response).to have_http_status(:not_found)
        # A rescued 404 does not persist the test sign-in's session; sign in again.
        sign_in business_manager
        reset_password(foreign)
        expect(response).to have_http_status(:not_found)
        expect(foreign.reload.first_name).not_to eq("Foreign")
      end
    end
  end

  # ── Privilege hierarchy (Cases A–E) ─────────────────────────────────────
  describe "privilege hierarchy" do
    let(:hr) { business_manager } # manage_employees, business-wide
    let(:role_admin) do
      api_user_with(business, :view_employees, :manage_employees, :manage_roles,
                    scopes: { "manage_employees" => "business" })
    end
    let(:regular)        { create(:user, business: business, permission_role: role_with(:view_attendance)) }
    let(:roles_admin_target) do
      create(:user, business: business, email: "roles-admin@example.com",
                    permission_role: role_with(:view_employees, :manage_employees, :manage_roles))
    end
    let(:employee_manager_target) do
      create(:user, business: business, permission_role: role_with(:view_employees, :manage_employees))
    end
    let(:settings_admin) { create(:user, business: business, permission_role: role_with(:manage_settings)) }

    it "Case A: manage_employees → regular employee: allowed" do
      sign_in hr
      reset_password(regular)
      expect(regular.reload.valid_password?("newpass1234")).to be(true)
      patch toggle_active_admin_user_path(regular)
      expect(regular.reload.active).to be(false)
    end

    describe "Case B: manage_employees → manage_roles administrator" do
      before { sign_in hr }

      it "cannot reset the administrator's password" do
        reset_password(roles_admin_target)
        expect(response).to redirect_to(root_path)
        expect(roles_admin_target.reload.valid_password?("newpass1234")).to be(false)
      end

      it "cannot deactivate the administrator (toggle or edit form)" do
        patch toggle_active_admin_user_path(roles_admin_target)
        expect(roles_admin_target.reload.active).to be(true)
        edit(roles_admin_target, active: "0")
        expect(roles_admin_target.reload.active).to be(true)
      end

      it "cannot delete the administrator" do
        delete admin_user_path(roles_admin_target)
        expect(User.exists?(roles_admin_target.id)).to be(true)
      end

      it "cannot take over the account through its login identifiers or remove its access" do
        warehouse = Warehouse.create!(business: business, name: "WH #{SecureRandom.hex(3)}")
        roles_admin_target.assigned_warehouses << warehouse
        edit(roles_admin_target, email: "attacker@example.com", phone_number: "+966509990000",
                                 assigned_warehouse_ids: [ "" ], first_name: "ProfileOnly")
        roles_admin_target.reload
        expect(roles_admin_target.email).to eq("roles-admin@example.com")
        expect(roles_admin_target.assigned_warehouses).to eq([ warehouse ])
        expect(roles_admin_target.first_name).to eq("ProfileOnly") # plain profile data stays editable
      end

      it "also applies to other administrative authority the actor lacks (manage_settings)" do
        reset_password(settings_admin)
        expect(settings_admin.reload.valid_password?("newpass1234")).to be(false)
      end
    end

    describe "Case C: manage_roles → manage_employees user" do
      it "allowed within scope" do
        sign_in role_admin
        reset_password(employee_manager_target)
        expect(employee_manager_target.reload.valid_password?("newpass1234")).to be(true)
        patch toggle_active_admin_user_path(employee_manager_target)
        expect(employee_manager_target.reload.active).to be(false)
      end

      it "denied outside the actor's branch scope" do
        branch_scoped_roles_admin =
          api_user_with(business, :view_employees, :manage_employees, :manage_roles,
                        scopes: { "manage_employees" => "branch" }).tap do |u|
            branch_a.update_column(:branch_manager_id, u.id)
          end
        target_b = employee_at(branch_b)
        target_b.update!(permission_role: role_with(:view_employees, :manage_employees))

        sign_in branch_scoped_roles_admin
        reset_password(target_b)
        expect(target_b.reload.valid_password?("newpass1234")).to be(false)
      end
    end

    describe "Case D: manage_roles → owner" do
      before do
        owner.update!(password: "ownerpass123", password_confirmation: "ownerpass123")
        sign_in role_admin
      end

      it "cannot reset, deactivate, delete or change the owner's role" do
        reset_password(owner)
        expect(owner.reload.valid_password?("ownerpass123")).to be(true)

        patch toggle_active_admin_user_path(owner)
        edit(owner, active: "0", permission_role_id: role_with(:view_attendance).id)
        delete admin_user_path(owner)

        owner.reload
        expect(owner.active).to be(true)
        expect(owner.permission_role).to be_nil
        expect(User.exists?(owner.id)).to be(true)
      end
    end

    describe "Case E: owner → administrator" do
      before { sign_in owner }

      it "keeps full capabilities" do
        reset_password(roles_admin_target)
        expect(roles_admin_target.reload.valid_password?("newpass1234")).to be(true)

        patch toggle_active_admin_user_path(roles_admin_target)
        expect(roles_admin_target.reload.active).to be(false)

        new_role = role_with(:view_attendance)
        edit(roles_admin_target, permission_role_id: new_role.id, email: "renamed-admin@example.com")
        roles_admin_target.reload
        expect(roles_admin_target.permission_role).to eq(new_role)
        expect(roles_admin_target.email).to eq("renamed-admin@example.com")
      end
    end
  end
end
