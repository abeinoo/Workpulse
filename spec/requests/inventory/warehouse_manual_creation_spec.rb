require "rails_helper"

# Manual warehouse creation from the Warehouses page: always a CENTRAL
# warehouse, through Inventory::WarehouseManager (one fail-closed audit entry).
# The kind is fixed by the controller — never read from the request — and
# branch warehouses come only from branch provisioning.
RSpec.describe "Inventory::Warehouses — manual creation is central", type: :request do
  let(:business)     { create(:business) }
  let(:owner)        { create(:user, :owner, business: business) }
  let(:company)      { user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses) }
  let(:manager)      { user_with_stock_permissions(business, :view_inventory, :manage_inventory) }
  let(:sales_branch) { create(:branch, business: business, name: "Shubra", branch_type: "sales") }

  def post_warehouse(as:, **attrs)
    sign_in as
    post inventory_warehouses_path,
         params: { warehouse: { name: "Riyadh Central", description: "Bulk stock", status: "active" }.merge(attrs) }
  end

  def warehouse_audits = AuditLog.where(auditable_type: "Warehouse")

  describe "successful creation" do
    it "creates a central warehouse for the owner, with no branch" do
      expect { post_warehouse(as: owner, status: "inactive") }.to change(Warehouse, :count).by(1)

      warehouse = Warehouse.order(:id).last
      expect(response).to redirect_to(inventory_warehouse_path(warehouse))
      expect(flash[:notice]).to eq(I18n.t("inventory.warehouses.created"))
      expect(warehouse).to have_attributes(kind: "central", branch_id: nil, business_id: business.id,
                                           name: "Riyadh Central", description: "Bulk stock", status: "inactive")
    end

    it "creates a central warehouse for an access_all_warehouses holder" do
      expect { post_warehouse(as: company) }.to change(Warehouse, :count).by(1)
      expect(Warehouse.order(:id).last).to have_attributes(kind: "central", branch_id: nil)
    end

    it "defaults a missing status to active" do
      post_warehouse(as: owner, status: "")
      expect(Warehouse.order(:id).last).to have_attributes(kind: "central", status: "active")
    end

    it "writes exactly one create audit entry naming the actor and the central kind" do
      post_warehouse(as: company)
      warehouse = Warehouse.order(:id).last

      audit = warehouse_audits.sole
      expect(audit).to have_attributes(action: "create", auditable_id: warehouse.id, actor_id: company.id,
                                       business_id: business.id)
      expect(audit.changes_json).to include("name" => [ nil, "Riyadh Central" ], "kind" => [ nil, "central" ],
                                            "branch_id" => [ nil, nil ], "status" => [ nil, "active" ])
      expect(audit.metadata).to include("business_id" => business.id, "kind" => "central", "branch_id" => nil)
      expect(audit.metadata).not_to have_key("source")
    end
  end

  describe "tampered parameters" do
    it "ignores a submitted kind and branch_id — still central, and the branch gets no warehouse" do
      expect { post_warehouse(as: owner, kind: "branch", branch_id: sales_branch.id) }.to change(Warehouse, :count).by(1)

      expect(Warehouse.order(:id).last).to have_attributes(kind: "central", branch_id: nil)
      expect(Warehouse.where(branch_id: sales_branch.id)).to be_empty
      expect(warehouse_audits.count).to eq(1)
    end

    it "ignores a submitted business_id" do
      other = create(:business)
      post_warehouse(as: owner, business_id: other.id)

      expect(Warehouse.order(:id).last.business_id).to eq(business.id)
      expect(other.warehouses).to be_empty
    end
  end

  describe "failures" do
    it "creates nothing when the audit entry cannot be written, and says so on the form" do
      fail_audit_writes!(:create)

      expect { post_warehouse(as: owner) }.not_to change(Warehouse, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(CGI.unescapeHTML(response.body)).to include(I18n.t("inventory.warehouses.errors.audit_failed"))
      expect(response.body).to include('value="Riyadh Central"') # the user's input is kept
    end

    it "refuses a duplicate name (case-insensitive) with the existing validation error" do
      business.warehouses.create!(name: "RIYADH CENTRAL", kind: "central")

      expect { post_warehouse(as: owner) }.not_to change(Warehouse, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expected = Warehouse.new.errors.full_message(:name, I18n.t("errors.messages.taken"))
      expect(CGI.unescapeHTML(response.body)).to include(expected)
      expect(warehouse_audits).to be_empty
    end

    it "refuses a blank name" do
      expect { post_warehouse(as: owner, name: "") }.not_to change(Warehouse, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(CGI.unescapeHTML(response.body)).to include(Warehouse.new.errors.full_message(:name, I18n.t("errors.messages.blank")))
    end

    it "refuses an unknown status without creating anything" do
      expect { post_warehouse(as: owner, status: "archived") }.not_to change(Warehouse, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(CGI.unescapeHTML(response.body)).to include(I18n.t("inventory.warehouses.errors.status_invalid"))
    end

    it "still refuses manage_inventory alone — no warehouse, no audit entry" do
      expect { post_warehouse(as: manager) }.not_to change(Warehouse, :count)
      expect(response).to redirect_to(root_path)
      expect(flash[:alert]).to eq(I18n.t("flash.not_authorized"))
      expect(warehouse_audits).to be_empty
    end
  end

  describe "existing warehouses" do
    it "leaves an existing unclassified warehouse exactly as it was" do
      legacy = business.warehouses.create!(name: "المخزن الرئيسي") # kind NULL, like warehouse #1
      legacy.update_columns(updated_at: 2.days.ago)
      before = legacy.reload.attributes

      post_warehouse(as: owner)

      expect(legacy.reload.attributes).to eq(before)
      expect(legacy.kind).to be_nil
      expect(warehouse_audits.where(auditable_id: legacy.id)).to be_empty
    end

    it "leaves an existing branch warehouse and its branch link untouched" do
      branch_warehouse = Branch.transaction do
        Inventory::BranchWarehouseProvisioning.provision!(branch: sales_branch, actor: owner)
      end
      before = branch_warehouse.reload.attributes

      post_warehouse(as: owner)

      expect(branch_warehouse.reload.attributes).to eq(before)
      expect(Warehouse.where(business_id: business.id, kind: "branch").pluck(:id, :branch_id))
        .to eq([ [ branch_warehouse.id, sales_branch.id ] ])
    end
  end

  describe "the new-warehouse form" do
    it "offers no kind or branch field" do
      sign_in owner
      get new_inventory_warehouse_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="warehouse[name]"')
      expect(response.body).not_to include('name="warehouse[kind]"')
      expect(response.body).not_to include('name="warehouse[branch_id]"')
    end
  end
end
