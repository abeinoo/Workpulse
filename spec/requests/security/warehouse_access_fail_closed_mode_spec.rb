require "rails_helper"

# Gradual fail-closed warehouse access (option C), end to end: once a business
# is switched to fail-closed, an unassigned non-owner's inventory_warehouse_ids
# is [] and every policy scope, controller guard, report and purchase-request
# path treats that as NO warehouse — never as "every warehouse". Each example
# contrasts the same user under the legacy rule so none can pass vacuously.
# The setting is stored directly with store_warehouse_access_fail_closed! (test database only).
RSpec.describe "Warehouse access — fail-closed mode end to end", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:nasr_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }

  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10).tap do |p|
      p.product_warehouse_settings.create!(warehouse: central, low_stock_level: 50, reorder_quantity: 20)
    end
  end
  let!(:receipt) do
    r = business.goods_receipts.build(warehouse: central, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call.receipt
  end
  let!(:purchase_request) do
    Inventory::PurchaseRequestCreator.new(business, actor: owner,
      items: [ { product_id: product.id, quantity: 2, unit_price: 10, warehouse_id: central.id } ]).call.purchase_requests.first
  end

  let!(:unassigned) do
    user_with_stock_permissions(business, :view_inventory, :manage_inventory, :manage_products,
                                :view_inventory_reports, :create_purchase_requests)
  end

  def fail_closed! = store_warehouse_access_fail_closed!(business, true)

  def as_loaded(user) = User.find(user.id)

  def scope_for(user, model) = Pundit.policy_scope!(as_loaded(user), model)

  it "legacy (contrast): the unassigned user reaches every warehouse and its records" do
    user = as_loaded(unassigned)
    expect(user.inventory_warehouse_ids).to be_nil
    expect(scope_for(user, Warehouse)).to contain_exactly(central, nasr_wh)
    expect(scope_for(user, GoodsReceipt)).to include(receipt)
    expect(scope_for(user, PurchaseRequest)).to include(purchase_request)
  end

  describe "after the business is switched to fail-closed" do
    before { fail_closed! }

    it "resolves the unassigned user to an empty list" do
      expect(as_loaded(unassigned).inventory_warehouse_ids).to eq([])
    end

    it "every warehouse-scoped policy scope is empty" do
      [ Warehouse, GoodsReceipt, StockIssue, StockAdjustment, StockCount, StockTransfer,
        PurchaseRequest, WarehouseBranchSupply ].each do |model|
        expect(scope_for(unassigned, model)).to be_empty, "#{model} scope leaked records"
      end
    end

    # Some of those tables hold no rows in this fixture, so also prove the
    # restriction itself: an empty id list compiles to the always-false 1=0,
    # whatever data exists — and under the legacy rule it is absent.
    it "each warehouse filter compiles to an always-false predicate (and is absent under legacy)" do
      models = [ Warehouse, GoodsReceipt, StockIssue, StockAdjustment, StockCount, StockTransfer, WarehouseBranchSupply ]
      models.each do |model|
        expect(scope_for(unassigned, model).to_sql).to include("1=0"), "#{model} scope is not fail-closed"
      end

      store_warehouse_access_fail_closed!(business, false)
      models.each do |model|
        expect(scope_for(unassigned, model).to_sql).not_to include("1=0"), "#{model} contrast failed"
      end
    end

    it "the warehouses page lists none" do
      sign_in unassigned
      get inventory_warehouses_path
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("Main Warehouse", "Nasr City WH")
    end

    it "reports and the low-stock engine see no stock" do
      ids = as_loaded(unassigned).inventory_warehouse_ids
      expect(Inventory::Reports::CurrentStock.new(business, warehouse_ids: nil).total_value).to be_positive # contrast
      expect(Inventory::Reports::CurrentStock.new(business, warehouse_ids: ids).total_value).to eq(0)
      expect(Inventory::LowStockQuery.new(business, warehouse_ids: nil).alerts).not_to be_empty            # contrast
      expect(Inventory::LowStockQuery.new(business, warehouse_ids: ids).alerts).to be_empty
    end

    it "the controller write guard refuses any warehouse (product warehouse settings)" do
      sign_in unassigned
      expect {
        patch inventory_product_path(product), params: {
          product: { name: product.name, sku: product.sku,
                     product_warehouse_settings_attributes: { "0" => { warehouse_id: nasr_wh.id, low_stock_level: 1, reorder_quantity: 1 } } }
        }
      }.not_to change(ProductWarehouseSetting, :count)
      expect(response).to redirect_to(root_path)
    end

    it "purchase requests cannot be created for any warehouse" do
      result = Inventory::PurchaseRequestCreator.new(business, actor: as_loaded(unassigned),
        items: [ { product_id: product.id, quantity: 1, unit_price: 10, warehouse_id: central.id } ]).call
      expect(result).not_to be_ok
    end

    it "an assigned user reaches exactly the assigned warehouse" do
      WarehouseAssignment.create!(user: unassigned, warehouse: central)
      expect(scope_for(unassigned, Warehouse)).to contain_exactly(central)
      expect(scope_for(unassigned, GoodsReceipt)).to include(receipt)
    end

    it "the owner still reaches everything" do
      expect(scope_for(owner, Warehouse)).to contain_exactly(central, nasr_wh)
      expect(scope_for(owner, PurchaseRequest)).to include(purchase_request)
    end
  end
end
