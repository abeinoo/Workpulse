require "rails_helper"

RSpec.describe Inventory::PurchaseRequestCreator, type: :model do
  let(:business)   { create(:business) }
  let(:actor)      { create(:user, :super_admin, business: business) }
  let(:supplier_1) { business.suppliers.create!(name: "Supplier 1") }
  let(:supplier_2) { business.suppliers.create!(name: "Supplier 2") }

  let(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let(:product_b) { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }
  let(:product_c) { business.products.create!(name: "Product C", sku: "C-1", average_cost_price: 150) }

  def item(product, supplier, qty:, price:)
    { product_id: product.id, quantity: qty, unit_price: price, supplier_id: supplier&.id }
  end

  def create_batch(items, idempotency_key: nil)
    described_class.new(business, actor: actor, items: items, source: "low_stock_alert",
                                  idempotency_key: idempotency_key).call
  end

  it "creates one purchase request from a single selected product" do
    result = create_batch([ item(product_a, supplier_1, qty: 10, price: 100) ])

    expect(result.ok?).to be(true)
    expect(result.purchase_requests.size).to eq(1)
    pr = result.purchase_requests.first
    expect(pr).to be_draft
    expect(pr.supplier).to eq(supplier_1)
    expect(pr.items.sole.product).to eq(product_a)
  end

  it "groups multiple selected products by supplier into one Purchase Request per supplier" do
    items = [
      item(product_a, supplier_1, qty: 10, price: 100),
      item(product_b, supplier_1, qty: 5,  price: 200),
      item(product_c, supplier_2, qty: 8,  price: 150)
    ]

    result = create_batch(items)

    expect(result.ok?).to be(true)
    expect(result.purchase_requests.size).to eq(2)

    pr1 = result.purchase_requests.find { |pr| pr.supplier_id == supplier_1.id }
    pr2 = result.purchase_requests.find { |pr| pr.supplier_id == supplier_2.id }

    expect(pr1.items.map(&:product)).to contain_exactly(product_a, product_b)
    expect(pr1.total_amount).to eq(10 * 100 + 5 * 200) # 2000
    expect(pr2.items.map(&:product)).to contain_exactly(product_c)
    expect(pr2.total_amount).to eq(8 * 150) # 1200
  end

  it "gives every generated request its own unique, sequential PR number" do
    items = [
      item(product_a, supplier_1, qty: 1, price: 10),
      item(product_c, supplier_2, qty: 1, price: 10)
    ]

    result = create_batch(items)
    numbers = result.purchase_requests.map(&:request_number)

    expect(numbers.uniq.size).to eq(2)
    expect(numbers).to all(match(/\APR-\d{6}\z/))
  end

  it "does not create a purchase request for an unselected product" do
    items = [ item(product_a, supplier_1, qty: 10, price: 100) ]

    result = create_batch(items)

    all_product_ids = result.purchase_requests.flat_map { |pr| pr.items.map(&:product_id) }
    expect(all_product_ids).to contain_exactly(product_a.id)
    expect(all_product_ids).not_to include(product_b.id)
  end

  it "computes line total as quantity * unit_price using the caller-provided (possibly edited) quantity" do
    result = create_batch([ item(product_a, supplier_1, qty: 12, price: 150) ])

    line = result.purchase_requests.first.items.sole
    expect(line.total_cost).to eq(1800)
  end

  it "computes the grand total per request as SUM(item totals)" do
    items = [
      item(product_a, supplier_1, qty: 10, price: 100),
      item(product_b, supplier_1, qty: 5,  price: 200)
    ]
    result = create_batch(items)

    expect(result.purchase_requests.first.total_amount).to eq(2000)
  end

  it "rejects the whole batch when any item is missing a supplier, without creating anything" do
    items = [
      item(product_a, supplier_1, qty: 10, price: 100),
      item(product_b, nil,        qty: 5,  price: 200)
    ]

    expect {
      result = create_batch(items)
      expect(result.ok?).to be(false)
      expect(result.missing_supplier_product_ids).to eq([ product_b.id ])
    }.not_to change(PurchaseRequest, :count)
  end

  it "rejects an item with no valid price rather than silently treating it as free" do
    items = [ item(product_a, supplier_1, qty: 10, price: 0) ]

    expect {
      result = create_batch(items)
      expect(result.ok?).to be(false)
    }.not_to change(PurchaseRequest, :count)
  end

  it "is atomic: if one supplier group is invalid, no request from the batch is created" do
    items = [
      item(product_a, supplier_1, qty: 10, price: 100),
      item(product_c, supplier_2, qty: -1, price: 150) # invalid quantity
    ]

    expect {
      result = create_batch(items)
      expect(result.ok?).to be(false)
    }.not_to change(PurchaseRequest, :count)
  end

  it "returns the previously created batch instead of creating duplicates on a retried idempotency key" do
    items = [ item(product_a, supplier_1, qty: 10, price: 100), item(product_c, supplier_2, qty: 8, price: 150) ]
    key = SecureRandom.uuid

    first  = create_batch(items, idempotency_key: key)
    expect {
      second = create_batch(items, idempotency_key: key)
      expect(second.ok?).to be(true)
      expect(second.purchase_requests.map(&:id)).to match_array(first.purchase_requests.map(&:id))
    }.not_to change(PurchaseRequest, :count)
  end

  it "tags every created request with the low_stock_alert source" do
    result = create_batch([ item(product_a, supplier_1, qty: 10, price: 100) ])
    expect(result.purchase_requests.first.source).to eq("low_stock_alert")
  end

  it "writes an audit log entry for every created request" do
    result = create_batch([
      item(product_a, supplier_1, qty: 10, price: 100),
      item(product_c, supplier_2, qty: 8, price: 150)
    ])

    result.purchase_requests.each do |pr|
      log = AuditLog.for_auditable(pr).last
      expect(log).to be_present
      expect(log.actor).to eq(actor)
      expect(log.action).to eq("create")
    end
  end

  it "starts every created request as draft, never auto-approving or auto-ordering" do
    result = create_batch([ item(product_a, supplier_1, qty: 10, price: 100) ])
    expect(result.purchase_requests).to all(be_draft)
  end

  it "never touches inventory — no movements, stock, or cost changes" do
    expect {
      create_batch([ item(product_a, supplier_1, qty: 10, price: 100) ])
    }.not_to change(InventoryMovement, :count)

    expect(product_a.reload.average_cost_price).to eq(100)
  end

  describe "server-side guards" do
    let(:warehouse_a) { business.warehouses.create!(name: "WH A") }
    let(:warehouse_b) { business.warehouses.create!(name: "WH B") }

    it "creates a request for any transactable product, with request-level notes and no source" do
      result = described_class.new(business, actor: actor, notes: "general order",
                                             items: [ item(product_a, supplier_1, qty: 2, price: 100) ]).call

      expect(result).to be_ok
      expect(result.purchase_requests.first.notes).to eq("general order")
      expect(result.purchase_requests.first.source).to be_nil
    end

    it "rejects a product from another business, an archived product, and a parent product" do
      foreign  = create(:business).products.create!(name: "F", sku: "F-1", average_cost_price: 1)
      archived = business.products.create!(name: "Arch", sku: "AR-1", average_cost_price: 1, active: false)
      parent   = business.products.create!(name: "Parent", sku: "P-1", average_cost_price: 1)
      business.products.create!(name: "Child", sku: "P-1-C", average_cost_price: 1, parent_product: parent)

      [ foreign, archived, parent ].each do |product|
        result = create_batch([ item(product, supplier_1, qty: 1, price: 1) ])
        expect(result).not_to be_ok
        expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.invalid_product"))
      end
      expect(PurchaseRequest.count).to eq(0)
    end

    it "rejects a warehouse the actor is not assigned to" do
      scoped = create(:user, business: business)
      WarehouseAssignment.create!(user: scoped, warehouse: warehouse_a)

      denied = described_class.new(business, actor: scoped, items: [
        item(product_a, supplier_1, qty: 1, price: 1).merge(source_warehouse_id: warehouse_b.id)
      ]).call
      allowed = described_class.new(business, actor: scoped, items: [
        item(product_a, supplier_1, qty: 1, price: 1).merge(source_warehouse_id: warehouse_a.id)
      ]).call

      expect(denied.error).to eq(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
      expect(allowed).to be_ok
    end

    it "requires an active warehouse on every line when require_warehouse is set" do
      build = ->(wh_id) {
        described_class.new(business, actor: actor, require_warehouse: true,
                                      items: [ item(product_a, supplier_1, qty: 1, price: 1).merge(source_warehouse_id: wh_id) ]).call
      }

      expect(build.(nil).error).to eq(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))
      warehouse_b.update!(status: "inactive")
      expect(build.(warehouse_b.id).error).to eq(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
      expect(build.(warehouse_a.id)).to be_ok
    end

    it "rejects the same product twice for the same warehouse, but allows it for different warehouses" do
      dup = create_batch([
        item(product_a, supplier_1, qty: 1, price: 1).merge(source_warehouse_id: warehouse_a.id),
        item(product_a, supplier_1, qty: 2, price: 1).merge(source_warehouse_id: warehouse_a.id)
      ])
      expect(dup.error).to eq(I18n.t("inventory.purchase_requests.errors.duplicate_product"))

      split = create_batch([
        item(product_a, supplier_1, qty: 1, price: 1).merge(source_warehouse_id: warehouse_a.id),
        item(product_a, supplier_1, qty: 2, price: 1).merge(source_warehouse_id: warehouse_b.id)
      ])
      expect(split).to be_ok
    end
  end
end
