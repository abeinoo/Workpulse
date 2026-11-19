require "rails_helper"

# Classifying an unclassified warehouse from the Warehouses page
# (Inventory::WarehouseClassificationsController -> WarehouseManager#classify).
RSpec.describe "Inventory::WarehouseClassifications", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:company)  { user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses) }
  let(:manager)  { user_with_stock_permissions(business, :view_inventory, :manage_inventory) }
  let(:viewer)   { user_with_stock_permissions(business, :view_inventory) }
  let(:shubra)   { create(:branch, business: business, name: "Shubra", branch_type: "sales") }

  let!(:legacy)  { business.warehouses.create!(name: "المخزن الرئيسي") } # like warehouse #1: kind NULL
  let!(:central) { business.warehouses.create!(name: "Riyadh Central", kind: "central") }

  def body = CGI.unescapeHTML(response.body)
  def classify_link(warehouse) = %(href="#{new_inventory_warehouse_classification_path(warehouse)}")
  def tab_count(key) = Nokogiri::HTML(response.body).at_css(%(.filter-tab[data-kind-filter="#{key}"] .badge)).text.to_i

  def post_classification(as:, warehouse: legacy, **attrs)
    sign_in as
    post inventory_warehouse_classification_path(warehouse), params: { classification: { reason: "Owner decision" }.merge(attrs) }
  end

  describe "index action" do
    it "offers Classify only on unclassified warehouses, to users who may classify" do
      sign_in owner
      get inventory_warehouses_path
      expect(body).to include(classify_link(legacy), I18n.t("inventory.warehouses.classification.action"))
      expect(body).not_to include(classify_link(central))

      sign_in company
      get inventory_warehouses_path
      expect(body).to include(classify_link(legacy))
    end

    it "hides Classify from manage_inventory alone and from viewers" do
      [ manager, viewer ].each do |user|
        sign_in user
        get inventory_warehouses_path
        expect(body).not_to include(classify_link(legacy))
      end
    end
  end

  describe "the form" do
    it "offers Central / Branch and only eligible branches" do
      eligible = shubra
      taken    = create(:branch, business: business, name: "Taken", branch_type: "sales")
      Branch.transaction { Inventory::BranchWarehouseProvisioning.provision!(branch: taken, actor: owner) }
      create(:branch, business: business, name: "Closed Sales", branch_type: "sales").update_column(:active, false)
      create(:branch, business: business, name: "Wash", branch_type: "laundry")
      create(:branch, business: create(:business), name: "Foreign Sales", branch_type: "sales")

      sign_in owner
      get new_inventory_warehouse_classification_path(legacy)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="classification[kind]"', 'value="central"', 'value="branch"',
                                       'name="classification[reason]"')
      expect(Nokogiri::HTML(response.body).at_css("#warehouse-classification-reason")["required"]).to be_present
      options = Nokogiri::HTML(response.body).css("#warehouse-classification-branch option").map(&:text)
      expect(options).to include(eligible.name)
      expect(options).not_to include("Taken", "Closed Sales", "Wash", "Foreign Sales")
      expect(body).to include(I18n.t("inventory.warehouses.classification.permanent"))
      expect(response.body).to include("data-turbo-confirm")
    end

    it "explains when no branch is available" do
      sign_in owner
      get new_inventory_warehouse_classification_path(legacy)
      expect(body).to include(I18n.t("inventory.warehouses.classification.no_branches"))
    end

    it "redirects an already classified warehouse back to the index" do
      sign_in owner
      get new_inventory_warehouse_classification_path(central)
      expect(response).to redirect_to(inventory_warehouses_path)
      expect(flash[:alert]).to eq(I18n.t("inventory.warehouses.errors.already_classified"))
    end

    it "refuses the page to manage_inventory alone" do
      sign_in manager
      get new_inventory_warehouse_classification_path(legacy)
      expect(response).to redirect_to(root_path)
    end

    it "404s another business's warehouse" do
      foreign = create(:business).warehouses.create!(name: "Foreign")
      sign_in owner
      get new_inventory_warehouse_classification_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "classifying" do
    it "classifies as central and the index shows the new type and counts" do
      sign_in owner
      get inventory_warehouses_path
      expect(tab_count("unclassified")).to eq(1)
      expect(tab_count("central")).to eq(1)

      post_classification(as: owner, kind: "central")
      expect(response).to redirect_to(inventory_warehouses_path)
      expect(flash[:notice]).to eq(I18n.t("inventory.warehouses.classification.classified",
                                          name: legacy.name, kind: I18n.t("inventory.warehouses.kinds.central")))
      expect(legacy.reload).to have_attributes(kind: "central", branch_id: nil)

      follow_redirect!
      expect(tab_count("unclassified")).to eq(0)
      expect(tab_count("central")).to eq(2)
      expect(body).not_to include(classify_link(legacy))
    end

    it "classifies as a branch warehouse and the index shows the branch" do
      post_classification(as: company, kind: "branch", branch_id: shubra.id)
      expect(legacy.reload).to have_attributes(kind: "branch", branch_id: shubra.id)
      expect(AuditLog.where(auditable_type: "Warehouse", action: "classify").sole.actor_id).to eq(company.id)

      get inventory_warehouses_path(kind: "branch")
      row = Nokogiri::HTML(response.body).css("table tbody tr").sole
      expect(row.at_css("td a").text).to eq(legacy.name)
      expect(row.css("td").find { |td| td["data-label"] == I18n.t("inventory.warehouses.branch") }.text.strip).to eq("Shubra")
      expect(tab_count("branch")).to eq(1)
    end

    it "re-renders with the error and changes nothing for a missing branch" do
      post_classification(as: owner, kind: "branch", branch_id: "")
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include(I18n.t("inventory.warehouses.errors.branch_required"))
      expect(legacy.reload.kind).to be_nil
    end

    it "refuses another business's branch, an inactive branch and a non-sales branch" do
      foreign  = create(:branch, business: create(:business), branch_type: "sales")
      inactive = create(:branch, business: business, branch_type: "sales").tap { |b| b.update_column(:active, false) }
      laundry  = create(:branch, business: business, branch_type: "laundry")

      { foreign => :branch_not_found, inactive => :branch_inactive, laundry => :branch_not_sales }.each do |branch, code|
        post_classification(as: owner, kind: "branch", branch_id: branch.id)
        expect(response).to have_http_status(:unprocessable_content)
        expect(body).to include(I18n.t("inventory.warehouses.errors.#{code}"))
      end
      expect(legacy.reload).to have_attributes(kind: nil, branch_id: nil)
    end

    it "requires a reason — missing or blank re-renders with the error and keeps the input" do
      sign_in owner
      post inventory_warehouse_classification_path(legacy), params: { classification: { kind: "central" } }
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include(I18n.t("inventory.warehouses.errors.classification_reason_required"))

      post_classification(as: owner, kind: "branch", branch_id: shubra.id, reason: "   ")
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include(I18n.t("inventory.warehouses.errors.classification_reason_required"))
      expect(Nokogiri::HTML(response.body).at_css("#warehouse-classification-branch option[selected]")["value"]).to eq(shubra.id.to_s)
      expect(legacy.reload.kind).to be_nil
      expect(AuditLog.where(auditable_type: "Warehouse", action: "classify")).to be_empty
    end

    it "refuses an over-long reason" do
      max = Inventory::WarehouseManager::CLASSIFICATION_REASON_MAX_LENGTH
      post_classification(as: owner, kind: "central", reason: "x" * (max + 1))
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include(I18n.t("inventory.warehouses.errors.classification_reason_too_long", count: max))
      expect(response.body).to include(%(maxlength="#{max}"))
      expect(legacy.reload.kind).to be_nil
    end

    it "records the reason in the audit entry" do
      post_classification(as: owner, kind: "central", reason: "  Bulk stock for every branch  ")
      audit = AuditLog.where(auditable_type: "Warehouse", action: "classify").sole
      expect(audit.actor_id).to eq(owner.id)
      expect(audit.metadata["reason"]).to eq("Bulk stock for every branch")
    end

    it "refuses an already classified warehouse" do
      post_classification(as: owner, warehouse: central, kind: "branch", branch_id: shubra.id)
      expect(response).to redirect_to(inventory_warehouses_path)
      expect(flash[:alert]).to eq(I18n.t("inventory.warehouses.errors.already_classified"))
      expect(central.reload).to have_attributes(kind: "central", branch_id: nil)
    end

    it "shows the audit failure and leaves the warehouse unclassified" do
      fail_audit_writes!(:classify)
      post_classification(as: owner, kind: "central")
      expect(response).to have_http_status(:unprocessable_content)
      expect(body).to include(I18n.t("inventory.warehouses.errors.audit_failed"))
      expect(legacy.reload.kind).to be_nil
    end

    it "refuses unauthorized users and other businesses' warehouses" do
      post_classification(as: manager, kind: "central")
      expect(response).to redirect_to(root_path)
      post_classification(as: viewer, kind: "central")
      expect(response).to redirect_to(root_path)
      expect(legacy.reload.kind).to be_nil

      foreign = create(:business).warehouses.create!(name: "Foreign")
      post_classification(as: owner, warehouse: foreign, kind: "central")
      expect(response).to have_http_status(:not_found)
      expect(foreign.reload.kind).to be_nil
    end

    it "ignores any other submitted attribute" do
      post_classification(as: owner, kind: "central", name: "Hacked", business_id: create(:business).id, status: "inactive")
      expect(legacy.reload).to have_attributes(kind: "central", name: "المخزن الرئيسي", business_id: business.id,
                                               status: "active")
    end
  end

  it "renders the page and messages in Arabic" do
    owner.update!(preferred_locale: "ar")
    sign_in owner
    get new_inventory_warehouse_classification_path(legacy)

    I18n.with_locale(:ar) do
      expect(body).to include(I18n.t("inventory.warehouses.classification.reason"),
                              I18n.t("inventory.warehouses.classification.title"),
                              I18n.t("inventory.warehouses.classification.kinds.central"),
                              I18n.t("inventory.warehouses.classification.kinds.branch"))
      post inventory_warehouse_classification_path(legacy), params: { classification: { kind: "branch", reason: "x" } }
      expect(body).to include(I18n.t("inventory.warehouses.errors.branch_required"))
      get inventory_warehouses_path
      expect(body).to include(I18n.t("inventory.warehouses.classification.action"))
    end
  end
end
