require "rails_helper"

RSpec.describe Inventory::PurchaseRequestCreator, type: :model do
  let(:business)   { create(:business) }
  let(:actor)      { create(:user, :super_admin, business: business) }
  let(:supplier_1) { business.suppliers.create!(name: "Supplier 1") }
  let(:supplier_2) { business.suppliers.create!(name: "Supplier 2") }
  let(:warehouse_a) { business.warehouses.create!(name: "WH A") }
  let(:warehouse_b) { business.warehouses.create!(name: "WH B") }
  # Every request names an eligible responsible employee (purchasing permission + active custody).
  let(:responsible) { purchaser_with_custody(business, first_name: "Rami") }

  let(:product_a) { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let(:product_b) { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }
  let(:product_c) { business.products.create!(name: "Product C", sku: "C-1", average_cost_price: 150) }

  def item(product, supplier, qty:, price:, warehouse: warehouse_a)
    { product_id: product.id, quantity: qty, unit_price: price, supplier_id: supplier&.id, warehouse_id: warehouse&.id }
  end

  def create_batch(items, idempotency_key: nil)
    described_class.new(business, responsible_employee_id: responsible.id, actor: actor, items: items, source: "low_stock_alert",
                                  idempotency_key: idempotency_key).call
  end

  it "creates one purchase request from a single selected product" do
    result = create_batch([ item(product_a, supplier_1, qty: 10, price: 100) ])

    expect(result.ok?).to be(true)
    expect(result.purchase_requests.size).to eq(1)
    pr = result.purchase_requests.first
    expect(pr).to be_draft
    expect(pr.warehouse).to eq(warehouse_a)
    expect(pr.supplier).to be_nil # the request-level supplier is legacy only
    expect(pr.items.sole.product).to eq(product_a)
    expect(pr.items.sole.supplier).to eq(supplier_1)
  end

  it "creates ONE request with one warehouse for lines of several suppliers" do
    items = [
      item(product_a, supplier_1, qty: 10, price: 100),
      item(product_b, supplier_2, qty: 5,  price: 200),
      item(product_c, nil,        qty: 8,  price: 150)
    ]

    result = create_batch(items)

    expect(result.ok?).to be(true)
    pr = result.purchase_requests.sole
    expect(pr.warehouse).to eq(warehouse_a)
    expect(pr.items.map { |i| [ i.product, i.supplier ] })
      .to contain_exactly([ product_a, supplier_1 ], [ product_b, supplier_2 ], [ product_c, nil ])
    expect(pr.items.map(&:source_warehouse_id)).to all(be_nil) # never the legacy per-line column
    expect(pr.total_amount).to eq(10 * 100 + 5 * 200 + 8 * 150)
  end

  it "groups the lines by warehouse into one Purchase Request per warehouse" do
    items = [
      item(product_a, supplier_1, qty: 10, price: 100, warehouse: warehouse_a),
      item(product_b, supplier_2, qty: 5,  price: 200, warehouse: warehouse_a),
      item(product_c, supplier_1, qty: 8,  price: 150, warehouse: warehouse_b)
    ]

    result = create_batch(items)

    expect(result.ok?).to be(true)
    expect(result.purchase_requests.size).to eq(2)
    in_a = result.purchase_requests.find { |pr| pr.warehouse_id == warehouse_a.id }
    in_b = result.purchase_requests.find { |pr| pr.warehouse_id == warehouse_b.id }
    expect(in_a.items.map(&:product)).to contain_exactly(product_a, product_b)
    expect(in_a.items.map(&:supplier)).to contain_exactly(supplier_1, supplier_2)
    expect(in_b.items.map(&:product)).to contain_exactly(product_c)
  end

  it "gives every generated request its own unique, sequential PR number" do
    items = [
      item(product_a, supplier_1, qty: 1, price: 10, warehouse: warehouse_a),
      item(product_c, supplier_2, qty: 1, price: 10, warehouse: warehouse_b)
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

  describe "line suppliers" do
    it "keeps the supplier chosen for the line, never touching the product's default supplier" do
      product_a.update!(default_supplier: supplier_1)

      result = create_batch([ item(product_a, supplier_2, qty: 1, price: 10) ])

      expect(result.purchase_requests.sole.items.sole.supplier).to eq(supplier_2)
      expect(product_a.reload.default_supplier).to eq(supplier_1)
    end

    it "accepts a line without a supplier (a product with no default supplier)" do
      result = create_batch([ item(product_a, nil, qty: 3, price: 100) ])

      expect(result.ok?).to be(true)
      expect(result.purchase_requests.sole.items.sole.supplier).to be_nil
    end

    it "treats a blank-string supplier_id (the modal's \"بدون مورد\") as no supplier" do
      result = create_batch([ item(product_a, nil, qty: 1, price: 10).merge(supplier_id: "") ])

      expect(result.ok?).to be(true)
      expect(result.purchase_requests.sole.items.sole.supplier_id).to be_nil
    end

    it "rejects a supplier from another business without creating anything" do
      foreign = create(:business).suppliers.create!(name: "Foreign")

      expect {
        result = create_batch([ item(product_a, nil, qty: 1, price: 10), item(product_b, foreign, qty: 1, price: 10) ])
        expect(result.ok?).to be(false)
        expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.invalid_supplier"))
      }.not_to change(PurchaseRequest, :count)
    end

    it "rejects the same product twice in one request even under different suppliers" do
      items = [ item(product_a, supplier_1, qty: 1, price: 10), item(product_a, supplier_2, qty: 1, price: 10) ]

      expect {
        result = create_batch(items)
        expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.duplicate_product"))
      }.not_to change(PurchaseRequest, :count)
    end
  end

  describe "idempotency" do
    it "returns the previously created batch instead of creating duplicates on a retried key" do
      items = [
        item(product_a, supplier_1, qty: 10, price: 100, warehouse: warehouse_a),
        item(product_c, supplier_2, qty: 8, price: 150, warehouse: warehouse_b)
      ]
      key = SecureRandom.uuid

      first = create_batch(items, idempotency_key: key)
      expect(first.purchase_requests.size).to eq(2)
      expect {
        second = create_batch(items, idempotency_key: key)
        expect(second.ok?).to be(true)
        expect(second.purchase_requests.map(&:id)).to match_array(first.purchase_requests.map(&:id))
      }.not_to change(PurchaseRequest, :count)
    end

    it "lets one batch key cover one request per warehouse (no index conflict)" do
      key = SecureRandom.uuid
      result = create_batch([
        item(product_a, supplier_1, qty: 1, price: 10, warehouse: warehouse_a),
        item(product_b, supplier_1, qty: 1, price: 10, warehouse: warehouse_b)
      ], idempotency_key: key)

      expect(result).to be_ok
      expect(PurchaseRequest.where(idempotency_key: key).pluck(:warehouse_id)).to contain_exactly(warehouse_a.id, warehouse_b.id)
    end

    it "backs up the batch key with a DB unique index: one request per warehouse per key" do
      key = SecureRandom.uuid
      create_batch([ item(product_a, nil, qty: 1, price: 10) ], idempotency_key: key)

      dup = PurchaseRequest.new(business: business, idempotency_key: key, created_by: actor, warehouse: warehouse_a)
      dup.items.build(product: product_b, quantity: 1, unit_price: 10)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "keeps at most one legacy no-supplier, no-warehouse request per key" do
      key = SecureRandom.uuid
      build = -> {
        PurchaseRequest.new(business: business, idempotency_key: key, created_by: actor).tap do |pr|
          pr.items.build(product: product_a, quantity: 1, unit_price: 10)
        end
      }
      build.call.save!

      expect { build.call.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  it "rejects an item with no valid price rather than silently treating it as free" do
    items = [ item(product_a, supplier_1, qty: 10, price: 0) ]

    expect {
      result = create_batch(items)
      expect(result.ok?).to be(false)
    }.not_to change(PurchaseRequest, :count)
  end

  it "is atomic: if one warehouse group is invalid, no request from the batch is created" do
    items = [
      item(product_a, supplier_1, qty: 10, price: 100, warehouse: warehouse_a),
      item(product_c, supplier_2, qty: -1, price: 150, warehouse: warehouse_b) # invalid quantity
    ]

    expect {
      result = create_batch(items)
      expect(result.ok?).to be(false)
    }.not_to change(PurchaseRequest, :count)
  end

  it "tags every created request with the low_stock_alert source" do
    result = create_batch([ item(product_a, supplier_1, qty: 10, price: 100) ])
    expect(result.purchase_requests.first.source).to eq("low_stock_alert")
  end

  it "writes an audit log entry for every created request, with its warehouse and line suppliers" do
    result = create_batch([
      item(product_a, supplier_1, qty: 10, price: 100, warehouse: warehouse_a),
      item(product_b, supplier_2, qty: 10, price: 100, warehouse: warehouse_a),
      item(product_c, supplier_2, qty: 8, price: 150, warehouse: warehouse_b)
    ])

    result.purchase_requests.each do |pr|
      log = AuditLog.for_auditable(pr).last
      expect(log).to be_present
      expect(log.actor).to eq(actor)
      expect(log.action).to eq("create")
      expect(log.metadata["warehouse_id"]).to eq(pr.warehouse_id)
    end
    in_a = result.purchase_requests.find { |pr| pr.warehouse_id == warehouse_a.id }
    expect(AuditLog.for_auditable(in_a).last.metadata["supplier_ids"]).to contain_exactly(supplier_1.id, supplier_2.id)
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
    it "creates a request for any transactable product, with request-level notes and no source" do
      result = described_class.new(business, responsible_employee_id: responsible.id, actor: actor, notes: "general order",
                                             items: [ item(product_a, supplier_1, qty: 2, price: 100) ]).call

      expect(result).to be_ok
      expect(result.purchase_requests.first.notes).to eq("general order")
      expect(result.purchase_requests.first.source).to be_nil
    end

    it "rejects a product from another business and an archived product" do
      foreign  = create(:business).products.create!(name: "F", sku: "F-1", average_cost_price: 1)
      archived = business.products.create!(name: "Arch", sku: "AR-1", average_cost_price: 1, active: false)

      [ foreign, archived ].each do |product|
        result = create_batch([ item(product, supplier_1, qty: 1, price: 1) ])
        expect(result).not_to be_ok
        expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.invalid_product"))
      end
      expect(PurchaseRequest.count).to eq(0)
    end

    it "never creates a request without a warehouse — from either entry point" do
      [ false, true ].each do |active_only|
        result = nil
        expect {
          result = described_class.new(business, responsible_employee_id: responsible.id, actor: actor, require_active_warehouse: active_only,
                                                 items: [ item(product_a, supplier_1, qty: 1, price: 1, warehouse: nil) ]).call
        }.not_to change(PurchaseRequest, :count)
        expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))
      end
    end

    it "rejects a warehouse of another business" do
      foreign_wh = create(:business).warehouses.create!(name: "Foreign WH")

      result = create_batch([ item(product_a, supplier_1, qty: 1, price: 1, warehouse: foreign_wh) ])

      expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
      expect(PurchaseRequest.count).to eq(0)
    end

    it "rejects a warehouse the actor is not assigned to" do
      scoped = create(:user, business: business)
      WarehouseAssignment.create!(user: scoped, warehouse: warehouse_a)

      denied = described_class.new(business, responsible_employee_id: responsible.id, actor: scoped, items: [
        item(product_a, supplier_1, qty: 1, price: 1, warehouse: warehouse_b)
      ]).call
      allowed = described_class.new(business, responsible_employee_id: responsible.id, actor: scoped, items: [
        item(product_a, supplier_1, qty: 1, price: 1, warehouse: warehouse_a)
      ]).call

      expect(denied.error).to eq(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
      expect(allowed).to be_ok
    end

    it "requires an active warehouse when require_active_warehouse is set (the general form)" do
      build = ->(wh) {
        described_class.new(business, responsible_employee_id: responsible.id, actor: actor, require_active_warehouse: true,
                                      items: [ item(product_a, supplier_1, qty: 1, price: 1, warehouse: wh) ]).call
      }

      warehouse_b.update!(status: "inactive")
      expect(build.(warehouse_b).error).to eq(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
      expect(build.(warehouse_a)).to be_ok
    end

    it "rejects the same product twice for the same warehouse, but allows it for different warehouses (separate requests)" do
      dup = create_batch([
        item(product_a, supplier_1, qty: 1, price: 1, warehouse: warehouse_a),
        item(product_a, supplier_1, qty: 2, price: 1, warehouse: warehouse_a)
      ])
      expect(dup.error).to eq(I18n.t("inventory.purchase_requests.errors.duplicate_product"))

      split = create_batch([
        item(product_a, supplier_1, qty: 1, price: 1, warehouse: warehouse_a),
        item(product_a, supplier_1, qty: 2, price: 1, warehouse: warehouse_b)
      ])
      expect(split).to be_ok
      expect(split.purchase_requests.size).to eq(2)
    end
  end

  describe "responsible employee (الموظف المسؤول عن الشراء)" do
    def create_with(responsible_employee_id)
      described_class.new(business, actor: actor, responsible_employee_id: responsible_employee_id,
                                    items: [ item(product_a, supplier_1, qty: 1, price: 10) ]).call
    end

    def message(key) = I18n.t("inventory.purchase_requests.errors.#{key}")

    it "assigns the eligible employee to every request of the batch and audits it" do
      result = described_class.new(business, actor: actor, responsible_employee_id: responsible.id.to_s,
                                             items: [ item(product_a, supplier_1, qty: 1, price: 10, warehouse: warehouse_a),
                                                      item(product_b, supplier_1, qty: 1, price: 10, warehouse: warehouse_b) ]).call

      expect(result).to be_ok
      expect(result.purchase_requests.map(&:responsible_employee)).to eq([ responsible, responsible ])
      expect(AuditLog.where(auditable: result.purchase_requests.first, action: "create").sole.metadata)
        .to include("responsible_employee_id" => responsible.id)
    end

    it "is optional: without one the request is created unassigned (never the actor)" do
      [ nil, "" ].each do |blank|
        result = create_with(blank)
        expect(result).to be_ok
        expect(result.purchase_requests.sole.responsible_employee_id).to be_nil
      end
      expect(PurchaseRequest.pluck(:responsible_employee_id)).to eq([ nil, nil ])
    end

    it "the Low Stock batch may be created without one too" do
      result = described_class.new(business, actor: actor, source: "low_stock_alert", idempotency_key: SecureRandom.uuid,
                                             items: [ item(product_a, supplier_1, qty: 1, price: 10, warehouse: warehouse_a),
                                                      item(product_b, supplier_1, qty: 1, price: 10, warehouse: warehouse_b) ]).call
      expect(result).to be_ok
      expect(result.purchase_requests.map(&:responsible_employee_id)).to eq([ nil, nil ])
    end

    it "must have the purchasing permission, an active custody account, be active and in this business" do
      no_permission = create(:user, business: business).tap { |u| create(:custody_account, business: business, user: u) }
      no_account    = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, purchaser_role_for(business).id) }
      inactive_acct = purchaser_with_custody(business).tap { |u| custody_of(u).update_column(:active, false) }
      inactive_user = purchaser_with_custody(business).tap { |u| u.update_column(:active, false) }
      foreign       = purchaser_with_custody(create(:business))

      [ no_permission, no_account, inactive_acct, inactive_user, foreign ].each do |user|
        expect(create_with(user.id).error).to eq(message(:responsible_employee_ineligible))
      end
      expect(create_with(999_999).error).to eq(message(:responsible_employee_ineligible))
      expect(PurchaseRequest.count).to eq(0)
    end
  end
end
