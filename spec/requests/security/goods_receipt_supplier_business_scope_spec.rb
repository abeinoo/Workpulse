require "rails_helper"

# SEC-P6-1 (found in Pilot 6 — Inventory & Purchasing Supplier, M0): a goods
# receipt without a purchase request accepted another business's supplier_id.
# The receipt was saved, the victim's Supplier#goods_receipts then listed the
# attacker's receipt, and the victim could no longer delete its supplier
# (restrict_with_error). GoodsReceipt now validates that its supplier belongs
# to the receipt's business (the PurchaseRequest#supplier_in_same_business rule);
# the purchase-request path keeps purchase_request_supplier_matches.
RSpec.describe "Security: goods receipt supplier business isolation", type: :request do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:receiver) { api_user_with(business, :view_inventory, :create_goods_receipts) }
  let!(:warehouse)        { business.warehouses.create!(name: "Main") }
  let!(:supplier)         { business.suppliers.create!(name: "Own Supplier") }
  let!(:foreign_supplier) { other.suppliers.create!(name: "Foreign Supplier") }
  let(:product) { business.products.create!(name: "Dye", sku: "DY-1", initial_cost_price: 1, average_cost_price: 1) }

  def receipt_params(supplier_id)
    { goods_receipt: { warehouse_id: warehouse.id, supplier_id: supplier_id, received_on: Date.current,
                       funding_source_kind: "supplier_credit",
                       items_attributes: { "0" => { product_id: product.id, quantity: 2, unit_cost: 5 } } } }
  end

  before { sign_in receiver }

  it "refuses a standalone receipt with another business's supplier (422, nothing saved)" do
    expect { post inventory_goods_receipts_path, params: receipt_params(foreign_supplier.id) }
      .not_to change(GoodsReceipt, :count)

    expect(response).to have_http_status(:unprocessable_entity)
    expect(foreign_supplier.goods_receipts).to be_empty
  end

  it "refuses moving a draft receipt to another business's supplier" do
    post inventory_goods_receipts_path, params: receipt_params(supplier.id)
    receipt = business.goods_receipts.sole

    patch inventory_goods_receipt_path(receipt), params: { goods_receipt: { supplier_id: foreign_supplier.id } }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(receipt.reload.supplier_id).to eq(supplier.id)
    expect(foreign_supplier.goods_receipts).to be_empty
  end

  it "still saves a standalone receipt with the business's own supplier" do
    expect { post inventory_goods_receipts_path, params: receipt_params(supplier.id) }.to change(GoodsReceipt, :count).by(1)

    expect(response).to redirect_to(inventory_goods_receipt_path(business.goods_receipts.sole))
    expect(business.goods_receipts.sole.supplier).to eq(supplier)
  end

  it "still saves a standalone receipt without a supplier (supplier stays optional)" do
    expect { post inventory_goods_receipts_path, params: receipt_params(nil) }.to change(GoodsReceipt, :count).by(1)
    expect(business.goods_receipts.sole.supplier).to be_nil
  end

  it "the model refuses a foreign supplier on every write path" do
    receipt = business.goods_receipts.build(warehouse: warehouse, supplier: foreign_supplier, received_on: Date.current)
    receipt.items.build(product: product, quantity: 1, unit_cost: 1)

    expect(receipt).not_to be_valid
    expect(receipt.errors[:supplier]).to be_present
  end
end
