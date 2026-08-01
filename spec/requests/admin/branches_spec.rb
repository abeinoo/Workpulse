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

    describe "Terminal IDs (nested)" do
      it "adds a new Terminal ID to the branch" do
        expect {
          patch admin_branch_path(branch), params: {
            branch: { pos_terminals_attributes: { "0" => { terminal_id: "TERM-1", label: "Front Desk", active: "1" } } }
          }
        }.to change { branch.pos_terminals.count }.by(1)

        expect(branch.pos_terminals.last.terminal_id).to eq("TERM-1")
      end

      it "edits an existing Terminal ID" do
        terminal = create(:pos_terminal, business: business, branch: branch, terminal_id: "OLD-ID")

        patch admin_branch_path(branch), params: {
          branch: { pos_terminals_attributes: { "0" => { id: terminal.id, terminal_id: "NEW-ID" } } }
        }

        expect(terminal.reload.terminal_id).to eq("NEW-ID")
      end

      it "deletes a Terminal ID via _destroy" do
        terminal = create(:pos_terminal, business: business, branch: branch)

        expect {
          patch admin_branch_path(branch), params: {
            branch: { pos_terminals_attributes: { "0" => { id: terminal.id, _destroy: "1" } } }
          }
        }.to change(PosTerminal, :count).by(-1)
      end

      it "rejects a Terminal ID that already exists elsewhere in the business" do
        other_branch = create(:branch, business: business)
        create(:pos_terminal, business: business, branch: other_branch, terminal_id: "DUP-ID")

        patch admin_branch_path(branch), params: {
          branch: { pos_terminals_attributes: { "0" => { terminal_id: "DUP-ID" } } }
        }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(branch.pos_terminals.where(terminal_id: "DUP-ID")).to be_empty
      end

      it "allows the same Terminal ID text in a different business" do
        other_business = create(:business)
        create(:pos_terminal, business: other_business, terminal_id: "SHARED-ID")

        patch admin_branch_path(branch), params: {
          branch: { pos_terminals_attributes: { "0" => { terminal_id: "SHARED-ID" } } }
        }

        expect(branch.reload.pos_terminals.pluck(:terminal_id)).to include("SHARED-ID")
      end

      it "sets business_id from the branch, not from user input" do
        patch admin_branch_path(branch), params: {
          branch: { pos_terminals_attributes: { "0" => { terminal_id: "TERM-AUTO" } } }
        }

        expect(branch.pos_terminals.find_by(terminal_id: "TERM-AUTO").business_id).to eq(business.id)
      end
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
