require "rails_helper"

# BUG-063 (Phase 1): deleting a product could wipe every warehouse's
# availability settings (dependent: :destroy) — even those outside the actor's
# warehouses — and crashed with a foreign-key error for a product referenced
# only by a purchase request line. Inventory::ProductDeletion now refuses any
# product with a trace, and audits a permitted deletion with a snapshot.
RSpec.describe Inventory::ProductDeletion do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:nasr_wh) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }

  # A product that may be deleted: archived, no barcode, no history, no references.
  def bare_product(sku = "SH-1")
    business.products.create!(name: "Shampoo #{sku}", sku: sku, initial_cost_price: 5, average_cost_price: 5).tap do |p|
      p.product_barcodes.delete_all
      p.update!(active: false, archived_at: Time.current)
    end
  end

  def delete(product, actor: owner) = described_class.new(actor: User.find(actor.id)).call(product_id: product.id)

  it "deletes an archived product with no trace, auditing a snapshot (fail-closed)" do
    product = bare_product
    result = delete(product)

    expect(result).to be_ok
    expect(Product.exists?(product.id)).to be(false)
    entry = AuditLog.where(action: "destroy", auditable_type: "Product", auditable_id: product.id).sole
    expect(entry.metadata["product"]).to include("sku" => "SH-1", "track_inventory" => true)
    expect(entry.metadata["product"].keys & RetiredProductStockColumns::COLUMNS).to be_empty
  end

  it "refuses a product with ANY warehouse availability row and keeps every row (the BUG-063 data loss)" do
    product = bare_product
    rows = [ central, nasr_wh ].map do |warehouse|
      product.product_warehouse_settings.create!(warehouse: warehouse, low_stock_level: 3, reorder_quantity: 10)
    end

    result = delete(product)

    expect(result.error).to eq(:referenced)
    expect(result.blockers).to eq(warehouse_availability: 2)
    expect(ProductWarehouseSetting.where(id: rows.map(&:id)).count).to eq(2)
    expect(Product.exists?(product.id)).to be(true)
  end

  it "refuses an Inactive availability row too" do
    product = bare_product
    product.product_warehouse_settings.create!(warehouse: central, low_stock_level: 3, reorder_quantity: 10,
                                               status: "inactive", status_reason: "x", status_changed_at: Time.current)
    expect(delete(product).blockers).to eq(warehouse_availability: 1)
  end

  it "refuses (instead of crashing) a product referenced only by a purchase request line" do
    product = bare_product
    product.update!(active: true, archived_at: nil)
    Inventory::PurchaseRequestCreator.new(business, actor: owner,
      items: [ { product_id: product.id, quantity: 2, unit_price: 5, warehouse_id: central.id } ]).call
    product.update!(active: false, archived_at: Time.current)

    result = delete(product)
    expect(result.error).to eq(:referenced)
    expect(result.blockers).to eq(purchase_request_lines: 1)
    expect(Product.exists?(product.id)).to be(true)
  end

  it "refuses an active (not archived) product" do
    product = bare_product.tap { |p| p.update!(active: true, archived_at: nil) }
    expect(delete(product).error).to eq(:not_archived)
  end

  it "refuses a product with inventory history (a barcode counts)" do
    product = business.products.create!(name: "Kept", sku: "KP-1", initial_cost_price: 5, average_cost_price: 5)
    product.update!(active: false, archived_at: Time.current)
    expect(product.product_barcodes).to exist
    expect(delete(product).error).to eq(:has_history)
  end

  it "refuses another business's product and an actor without the permission" do
    foreign = other.products.create!(name: "F", sku: "F-1", initial_cost_price: 1, average_cost_price: 1)
    viewer  = user_with_stock_permissions(business, :view_inventory)
    expect(delete(foreign).error).to eq(:not_authorized)
    expect(delete(bare_product, actor: viewer).error).to eq(:not_authorized)
  end

  it "keeps the product when the audit entry cannot be written" do
    product = bare_product
    fail_audit_writes!(:destroy)
    expect(delete(product).error).to eq(:audit_failed)
    expect(Product.exists?(product.id)).to be(true)
  end

  it "the model backstop: destroying a product with availability rows outside the service is refused" do
    product = bare_product
    product.product_warehouse_settings.create!(warehouse: central, low_stock_level: 3, reorder_quantity: 10)
    expect(product.destroy).to be(false)
    expect(ProductWarehouseSetting.where(product_id: product.id)).to exist
  end
end
