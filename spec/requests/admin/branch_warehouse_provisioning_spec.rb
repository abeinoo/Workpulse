require "rails_helper"

# Warehouse Architecture — PR 3 through the Branch form: a sales branch is
# saved with its branch warehouse, or — when provisioning is refused — not at
# all, and the form is re-rendered with the reason.
RSpec.describe "Admin branches — branch warehouse provisioning", type: :request do
  let(:business) { create(:business) }
  let(:admin)    { api_user_with(business, :manage_branches) }

  before { sign_in admin }

  def provisioning_error(name)
    I18n.t("admin.branches.warehouse_provisioning_failed",
           reason: I18n.t("inventory.warehouses.errors.name_taken", name: name))
  end

  describe "POST /admin/branches" do
    it "creates a sales branch together with its branch warehouse" do
      expect {
        post admin_branches_path, params: { branch: { name: "Shubra", address: "St 1", branch_type: "sales" } }
      }.to change(Branch, :count).by(1).and change(Warehouse, :count).by(1)

      branch = Branch.order(:id).last
      expect(response).to redirect_to(admin_branch_path(branch))
      expect(Warehouse.find_by!(branch_id: branch.id).name).to eq("Shubra – المخزن")
    end

    it "re-renders the form with the reason and saves nothing when the warehouse name is taken" do
      business.warehouses.create!(name: "Shubra – المخزن", kind: "central")

      expect {
        post admin_branches_path, params: { branch: { name: "Shubra", address: "St 1", branch_type: "sales",
                                                      pos_terminals_attributes: { "0" => { terminal_id: "T-9" } } } }
      }.not_to change { [ Branch.count, Warehouse.count, PosTerminal.count, AuditLog.count ] }

      expect(response).to have_http_status(:unprocessable_entity)
      body = CGI.unescapeHTML(response.body)
      expect(body).to include(provisioning_error("Shubra – المخزن"))
      expect(body).to include(%(action="#{admin_branches_path}")) # the new-branch form again
      expect(body).to include('value="Shubra"')                  # with what was submitted
    end
  end

  describe "PATCH /admin/branches/:id" do
    let!(:laundry) { create(:branch, business: business, name: "Wash", branch_type: "laundry") }

    it "provisions the warehouse when a branch becomes a sales branch" do
      patch admin_branch_path(laundry), params: { branch: { branch_type: "sales" } }

      expect(response).to redirect_to(admin_branch_path(laundry))
      expect(Warehouse.where(branch_id: laundry.id).count).to eq(1)
    end

    it "re-renders the edit form with the reason and keeps the branch unchanged when provisioning fails" do
      business.warehouses.create!(name: "Wash – المخزن", kind: "central")

      patch admin_branch_path(laundry), params: { branch: { branch_type: "sales", address: "Changed" } }

      expect(response).to have_http_status(:unprocessable_entity)
      body = CGI.unescapeHTML(response.body)
      expect(body).to include(provisioning_error("Wash – المخزن"))
      expect(body).to include(%(action="#{admin_branch_path(laundry)}"))
      expect(laundry.reload).to have_attributes(branch_type: "laundry", address: laundry.address)
      expect(Warehouse.where(branch_id: laundry.id)).to be_empty
    end
  end
end
