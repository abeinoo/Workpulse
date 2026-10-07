require "rails_helper"

# SEC-P6-3 (found in Pilot 6 — Inventory & Purchasing Supplier, M0): the
# supplier page listed the supplier's recent goods receipts straight from
# Supplier#goods_receipts, so a user restricted to some warehouses saw receipt
# numbers, warehouse names, dates and totals from warehouses outside their
# scope (opening such a receipt already returned 404). The summary now goes
# through GoodsReceiptPolicy::Scope — the same business and warehouse scope as
# the receipts themselves.
RSpec.describe "Security: supplier receipt summary scope", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:supplier)     { business.suppliers.create!(name: "Acme") }
  let!(:own_wh)       { business.warehouses.create!(name: "Own Warehouse") }
  let!(:hidden_wh)    { business.warehouses.create!(name: "Hidden Warehouse") }
  let(:product)       { business.products.create!(name: "Dye", sku: "DY-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:own_receipt)    { receipt(own_wh, 11) }
  let!(:hidden_receipt) { receipt(hidden_wh, 22) }

  def receipt(warehouse, cost)
    r = business.goods_receipts.build(warehouse: warehouse, supplier: supplier, received_on: Date.current)
    r.items.build(product: product, quantity: 1, unit_cost: cost)
    Inventory::GoodsReceiptPoster.new(r).call
    r.reload
  end

  it "a warehouse-restricted user sees only receipts from their warehouses" do
    restricted = api_user_with(business, :view_inventory)
    WarehouseAssignment.create!(user: restricted, warehouse: own_wh)
    sign_in restricted

    get inventory_supplier_path(supplier)

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(own_receipt.receipt_number)
    expect(response.body).not_to include(hidden_receipt.receipt_number, "Hidden Warehouse")
  end

  it "a user without warehouse restrictions still sees every receipt of the supplier" do
    sign_in api_user_with(business, :view_inventory)

    get inventory_supplier_path(supplier)

    expect(response.body).to include(own_receipt.receipt_number, hidden_receipt.receipt_number)
  end

  it "never lists another business's receipt, even one pointing at this supplier (legacy data)" do
    other_wh = other.warehouses.create!(name: "Other Business Warehouse")
    other_product = other.products.create!(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1)
    foreign = other.goods_receipts.build(warehouse: other_wh, received_on: Date.current)
    foreign.items.build(product: other_product, quantity: 1, unit_cost: 1)
    Inventory::GoodsReceiptPoster.new(foreign).call
    foreign.reload.update_column(:supplier_id, supplier.id)
    sign_in api_user_with(business, :view_inventory)

    get inventory_supplier_path(supplier)

    # Receipt numbers are sequenced per business, so match the foreign receipt's link and warehouse instead.
    expect(response.body).not_to include(inventory_goods_receipt_path(foreign), "Other Business Warehouse")
    expect(response.body).to include(inventory_goods_receipt_path(own_receipt))
  end
end
