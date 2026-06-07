require "rails_helper"

RSpec.describe "Product default supplier", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:supplier) { business.suppliers.create!(name: "Acme Supplies") }

  before { sign_in owner }

  it "stores a default supplier on the product" do
    post inventory_products_path, params: {
      product: { name: "Conditioner", sku: "CN-1", initial_cost_price: 3, default_supplier_id: supplier.id }
    }
    product = business.products.find_by!(sku: "CN-1")
    expect(product.default_supplier).to eq(supplier)
  end

  it "still records purchase history across multiple suppliers (default is not exclusive)" do
    other = business.suppliers.create!(name: "Beta Supplies")
    wh = business.warehouses.create!(name: "Main")
    product = business.products.create!(name: "Dye", sku: "DY-1", initial_cost_price: 0, average_cost_price: 0, default_supplier: supplier)

    [ [ supplier, 100 ], [ other, 120 ] ].each do |sup, cost|
      r = business.goods_receipts.build(warehouse: wh, supplier: sup, received_on: Date.current)
      r.items.build(product: product, quantity: 5, unit_cost: cost)
      Inventory::GoodsReceiptPoster.new(r).call
    end

    history = product.goods_receipt_items.includes(:goods_receipt).map { |i| [ i.goods_receipt.supplier, i.unit_cost ] }
    expect(history).to contain_exactly([ supplier, 100 ], [ other, 120 ])
  end

  it "exposes the default supplier id on receipt product options for auto-fill" do
    business.products.create!(name: "Dye", sku: "DY-2", initial_cost_price: 1, default_supplier: supplier)
    business.warehouses.create!(name: "Main")
    get new_inventory_goods_receipt_path
    expect(response.body).to include("data-default-supplier-id=\"#{supplier.id}\"")
    expect(response.body).to include("receipt-supplier")
  end
end
