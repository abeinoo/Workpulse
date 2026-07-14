require "rails_helper"

RSpec.describe "Admin::Branches", type: :request do
  let(:business)    { create(:business) }
  let(:super_admin) { create(:user, :super_admin, business: business) }
  let(:branch)      { create(:branch, business: business) }
  let(:shift)       { create(:shift, :fixed_time, business: business) }

  before { sign_in super_admin }

  describe "GET /admin/branches/:id" do
    it "returns 200 and lists employees assigned to the branch via active ShiftAssignment" do
      assigned   = create(:user, business: business, first_name: "Assigned", last_name: "Member")
      unassigned = create(:user, business: business, first_name: "Unassigned", last_name: "Person")
      create(:shift_assignment, user: assigned, branch: branch, shift: shift)

      get admin_branch_path(branch)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Assigned Member")
      expect(response.body).not_to include("Unassigned Person")
    end

    it "renders with no employees when the branch has no active assignments" do
      get admin_branch_path(branch)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /admin/branches" do
    it "returns 200" do
      get admin_branches_path
      expect(response).to have_http_status(:ok)
    end

    it "displays the translated branch type, never the raw enum value" do
      laundry = create(:branch, business: business, branch_type: "laundry", name: "دراي كلين")

      get admin_branches_path

      expect(response.body).to include(I18n.t("admin.branches.branch_types.laundry"))
      expect(response.body).not_to match(%r{>\s*laundry\s*<})
      laundry.destroy
    end
  end

  describe "GET /admin/branches/new" do
    it "shows a required Branch Type select" do
      get new_admin_branch_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="branch[branch_type]"')
      expect(response.body).to include(I18n.t("admin.branches.branch_types.sales"))
      expect(response.body).to include(I18n.t("admin.branches.branch_types.laundry"))
    end
  end

  describe "GET /admin/branches/:id/edit" do
    it "shows the Branch Type select preset to the branch's current type" do
      branch.update!(branch_type: "laundry")

      get edit_admin_branch_path(branch)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="branch[branch_type]"')
    end
  end

  describe "POST /admin/branches" do
    it "creates a branch with the selected branch_type" do
      post admin_branches_path, params: { branch: { name: "New Warehouse", branch_type: "warehouse" } }

      branch = Branch.last
      expect(response).to redirect_to(admin_branch_path(branch))
      expect(branch.branch_type).to eq("warehouse")
    end

    it "rejects an unsupported branch_type value instead of raising, and re-renders the form" do
      expect {
        post admin_branches_path, params: { branch: { name: "Bad Branch", branch_type: "not_a_real_type" } }
      }.not_to raise_error

      expect(response).to have_http_status(:unprocessable_entity)
      expect(Branch.exists?(name: "Bad Branch")).to be(false)
    end
  end

  describe "PATCH /admin/branches/:id" do
    it "updates the branch_type, preserving historical records that reference the branch" do
      shift_assignment = create(:shift_assignment, business: business, branch: branch, shift: shift)

      patch admin_branch_path(branch), params: { branch: { branch_type: "warehouse" } }

      expect(branch.reload.branch_type).to eq("warehouse")
      expect(shift_assignment.reload.branch_id).to eq(branch.id) # historical reference untouched
    end

    it "rejects an unsupported branch_type value instead of raising" do
      expect {
        patch admin_branch_path(branch), params: { branch: { branch_type: "not_a_real_type" } }
      }.not_to raise_error

      expect(response).to have_http_status(:unprocessable_entity)
      expect(branch.reload.branch_type).to eq("sales") # unchanged
    end
  end

  describe "authorization" do
    it "denies a user without manage_branches from creating a branch" do
      role = business.permission_roles.create!(name: "No Branch Access", permissions: [])
      no_access = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
      sign_in no_access

      post admin_branches_path, params: { branch: { name: "Sneaky Branch", branch_type: "sales" } }

      expect(Branch.exists?(name: "Sneaky Branch")).to be(false)
    end

    it "denies a user without manage_branches from changing an existing branch's type" do
      role = business.permission_roles.create!(name: "No Branch Access", permissions: [])
      no_access = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
      sign_in no_access

      patch admin_branch_path(branch), params: { branch: { branch_type: "warehouse" } }

      expect(branch.reload.branch_type).to eq("sales")
    end
  end
end
