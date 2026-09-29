require "rails_helper"

RSpec.describe "Inventory warehouse → branch supply links", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main Warehouse") }
  let!(:north)   { business.warehouses.create!(name: "North Warehouse") }
  let!(:shubra)  { business.branches.create!(name: "Shubra Branch", active: true) }
  let!(:nasr)    { business.branches.create!(name: "Nasr Branch", active: true) }
  let(:product)  { business.products.create!(name: "Dye", sku: "D-1", initial_cost_price: 5, average_cost_price: 5, reorder_level: 100, reorder_quantity: 10) }

  def user_with(permissions, warehouses: [])
    role = business.permission_roles.create!(name: "R#{permissions.join}#{warehouses.size}", permissions: permissions)
    create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, role.id)
      warehouses.each { |w| u.assigned_warehouses << w }
    end
  end

  def set_link(branch, wh, active: "true")
    patch inventory_warehouse_supply_path(branch), params: { warehouse_id: wh.id, active: active }
  end

  describe "admin with manage_inventory" do
    before { sign_in owner }

    it "is listed in Inventory Settings with its description" do
      get inventory_settings_path
      expect(response.body).to include(I18n.t("inventory.warehouse_supplies.title"), inventory_warehouse_supplies_path)
    end

    it "lists branches with supplying warehouse, status and a change action; saves and changes links" do
      get inventory_warehouse_supplies_path
      expect(response.body).to include("Shubra Branch", "Nasr Branch", I18n.t("inventory.warehouse_supplies.statuses.unlinked"))

      set_link(shubra, main)
      set_link(nasr, main) # one warehouse may supply several branches
      expect(response).to redirect_to(inventory_warehouse_supplies_path)
      expect(WarehouseBranchSupply.pluck(:branch_id, :warehouse_id)).to contain_exactly([ shubra.id, main.id ], [ nasr.id, main.id ])

      set_link(nasr, north)
      expect(nasr.reload.warehouse_supply.warehouse).to eq(north)
      expect(WarehouseBranchSupply.count).to eq(2)

      get inventory_warehouse_supplies_path
      expect(response.body).to include(I18n.t("inventory.warehouse_supplies.sources.explicit"))
    end

    it "shows the inferred relationship, clearly labelled, without saving it" do
      r = business.goods_receipts.build(warehouse: main, received_on: Date.current)
      r.items.build(product: product, quantity: 5, unit_cost: 5)
      Inventory::GoodsReceiptPoster.new(r).call
      i = business.stock_issues.build(warehouse: main, branch: shubra, issued_on: Date.current)
      i.items.build(product: product, quantity: 1)
      Inventory::StockIssuePoster.new(i).call

      get inventory_warehouse_supplies_path
      expect(response.body).to include(I18n.t("inventory.warehouse_supplies.sources.inferred"),
                                       I18n.t("inventory.warehouse_supplies.statuses.inferred"))
      expect(WarehouseBranchSupply.count).to eq(0)
    end

    it "cannot touch another business's branches or warehouses" do
      other = create(:business)
      foreign_branch = other.branches.create!(name: "Foreign", active: true)
      foreign_wh = other.warehouses.create!(name: "Foreign WH")
      patch inventory_warehouse_supply_path(foreign_branch), params: { warehouse_id: main.id }
      expect(response).to have_http_status(:not_found)
      sign_in owner # the 404 response above drops the test session
      set_link(shubra, foreign_wh)
      expect(response).to have_http_status(:not_found)
      expect(WarehouseBranchSupply.count).to eq(0)
    end

    it "renders right-to-left in Arabic" do
      owner.update!(preferred_locale: "ar")
      get inventory_warehouse_supplies_path
      expect(response.body).to match(/<html[^>]*dir="rtl"/)
      expect(response.body).to include("ربط المخازن بالفروع", "حدد المخزن الذي يخدم كل فرع")
      expect(response.body).not_to include("translation missing")
    end
  end

  describe "permissions" do
    it "view_inventory can see links but not change them" do
      sign_in user_with(%w[view_inventory])
      get inventory_warehouse_supplies_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(I18n.t("inventory.warehouse_supplies.set"))

      set_link(shubra, main)
      expect(WarehouseBranchSupply.count).to eq(0)
    end

    it "a warehouse-scoped manager only sees and assigns links involving their warehouses" do
      Inventory::WarehouseSupplyAssigner.new(branch_id: nasr.id, warehouse_id: north.id, active: true, actor: owner).call
      manager = user_with(%w[view_inventory manage_inventory], warehouses: [ main ])
      sign_in manager

      get inventory_warehouse_supplies_path
      expect(response.body).not_to include("Nasr Branch") # linked to North, which they can't access
      expect(response.body).not_to include("Shubra Branch") # unlinked branches are for unscoped admins

      set_link(shubra, north) # can't assign to a warehouse they can't access
      expect(WarehouseBranchSupply.find_by(branch: shubra)).to be_nil

      set_link(nasr, main) # can't take over a link that points at a warehouse they can't access
      expect(nasr.reload.warehouse_supply.warehouse).to eq(north)

      set_link(shubra, main)
      expect(shubra.reload.warehouse_supply.warehouse).to eq(main)
    end

    it "users without inventory access are turned away" do
      sign_in create(:user, business: business)
      get inventory_warehouse_supplies_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "low stock report branch filter" do
    before do
      [ [ main, 2 ], [ north, 3 ] ].each do |wh, qty|
        r = business.goods_receipts.build(warehouse: wh, received_on: Date.current)
        r.items.build(product: product, quantity: qty, unit_cost: 5)
        Inventory::GoodsReceiptPoster.new(r).call
      end
      product.product_warehouse_settings.create!(warehouse: main, low_stock_level: 10, reorder_quantity: 20)
      product.product_warehouse_settings.create!(warehouse: north, low_stock_level: 10, reorder_quantity: 20)
      Inventory::WarehouseSupplyAssigner.new(branch_id: shubra.id, warehouse_id: north.id, active: true, actor: owner).call
      sign_in owner
    end

    it "narrows alerts to the branch's supplying warehouse" do
      get inventory_low_stock_report_path, params: { branch_id: shubra.id }
      table = response.body[/<tbody>.*<\/tbody>/m]
      expect(table).to include("North Warehouse")
      expect(table).not_to include("Main Warehouse")
    end
  end
end
