require "rails_helper"
require Rails.root.join("db/migrate/20261113130100_backfill_purchase_request_item_suppliers_and_warehouse")

# The backfill gives requests created before the warehouse/supplier refactor
# the same shape as new ones — line suppliers from the request's one
# supplier, a request warehouse only when every line named the same one —
# writing only the EMPTY new columns and never the legacy ones.
RSpec.describe "BackfillPurchaseRequestItemSuppliersAndWarehouse" do
  let(:business) { create(:business) }
  let(:acme)     { business.suppliers.create!(name: "Acme") }
  let(:beta)     { business.suppliers.create!(name: "Beta") }
  let(:main_wh)  { business.warehouses.create!(name: "Main") }
  let(:annex)    { business.warehouses.create!(name: "Annex") }
  let(:product_a) { business.products.create!(name: "A", sku: "A-1", average_cost_price: 1) }
  let(:product_b) { business.products.create!(name: "B", sku: "B-1", average_cost_price: 1) }

  # A pre-refactor request: request-level supplier, per-line warehouses.
  def legacy_request(supplier:, line_warehouses:)
    pr = business.purchase_requests.build(supplier: supplier)
    line_warehouses.zip([ product_a, product_b ]).each do |wh, product|
      pr.items.build(product: product, quantity: 1, unit_price: 1, source_warehouse: wh)
    end
    pr.save!
    pr
  end

  def backfill!
    ActiveRecord::Base.connection.execute(BackfillPurchaseRequestItemSuppliersAndWarehouse::ITEM_SUPPLIER_SQL)
    ActiveRecord::Base.connection.execute(BackfillPurchaseRequestItemSuppliersAndWarehouse::REQUEST_WAREHOUSE_SQL)
  end

  it "copies the request's supplier to its lines and keeps the legacy columns" do
    pr = legacy_request(supplier: acme, line_warehouses: [ main_wh, main_wh ])
    backfill!

    pr.reload
    expect(pr.items.map(&:supplier_id)).to all(eq(acme.id))
    expect(pr.supplier_id).to eq(acme.id)
    expect(pr.items.map(&:source_warehouse_id)).to all(eq(main_wh.id))
  end

  it "sets the request warehouse only when every line names the same one" do
    same    = legacy_request(supplier: acme, line_warehouses: [ main_wh, main_wh ])
    mixed   = legacy_request(supplier: acme, line_warehouses: [ main_wh, annex ])
    partial = legacy_request(supplier: acme, line_warehouses: [ main_wh, nil ])
    none    = legacy_request(supplier: nil, line_warehouses: [ nil ])
    backfill!

    expect(same.reload.warehouse_id).to eq(main_wh.id)
    expect(mixed.reload.warehouse_id).to be_nil
    expect(partial.reload.warehouse_id).to be_nil
    expect(none.reload.warehouse_id).to be_nil
    expect(none.items.first.supplier_id).to be_nil
  end

  it "never overwrites a value already present in the new columns, and is safe to re-run" do
    pr = legacy_request(supplier: acme, line_warehouses: [ main_wh ])
    pr.update_column(:warehouse_id, annex.id)
    pr.items.first.update_column(:supplier_id, beta.id)
    2.times { backfill! }

    expect(pr.reload.warehouse_id).to eq(annex.id)
    expect(pr.items.first.supplier_id).to eq(beta.id)
  end

  it "leaves a backfilled legacy request receivable exactly as before (locked to its supplier)" do
    pr = legacy_request(supplier: acme, line_warehouses: [ main_wh ])
    backfill!
    pr.update_column(:status, "approved")

    receipt = business.goods_receipts.build(warehouse: main_wh, supplier: acme, received_on: Date.current,
                                            purchase_request: pr, funding_source_kind: "supplier_credit")
    receipt.items.build(product: product_a, quantity: 1, unit_cost: 1, purchase_request_item: pr.items.first)
    expect(receipt).to be_valid

    receipt.supplier = beta
    expect(receipt).not_to be_valid
  end
end
