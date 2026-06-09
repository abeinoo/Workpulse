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
  end
end
