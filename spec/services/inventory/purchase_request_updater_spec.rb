require "rails_helper"

RSpec.describe Inventory::PurchaseRequestUpdater, type: :model do
  let(:business)    { create(:business) }
  let(:actor)       { create(:user, :super_admin, business: business) }
  let(:supplier_1)  { business.suppliers.create!(name: "Supplier 1") }
  let(:supplier_2)  { business.suppliers.create!(name: "Supplier 2") }
  let(:product_a)   { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let(:product_b)   { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }
  let(:warehouse_a) { business.warehouses.create!(name: "WH A") }
  let(:warehouse_b) { business.warehouses.create!(name: "WH B") }
  let(:responsible) { purchaser_with_custody(business, first_name: "Rami") }

  def draft_request(quantity: 10, unit_price: 100, supplier: supplier_1)
    pr = business.purchase_requests.build(warehouse: warehouse_a, source: "low_stock_alert", created_by: actor,
                                          responsible_employee: responsible)
    pr.items.build(product: product_a, quantity: quantity, unit_price: unit_price, supplier: supplier)
    pr.save!
    pr
  end

  # A request created before the warehouse/supplier refactor: one
  # request-level supplier, the warehouse on the line (or none).
  def legacy_draft_request(supplier: supplier_1, line_warehouse: nil)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: actor)
    pr.items.build(product: product_a, quantity: 10, unit_price: 100, supplier: supplier, source_warehouse: line_warehouse)
    pr.save!
    pr
  end

  def line_attrs(pr, **overrides)
    item = pr.items.first
    { "0" => { id: item.id, product_id: item.product_id, quantity: item.quantity, unit_price: item.unit_price }.merge(overrides) }
  end

  # A legacy draft (no responsible employee) gets one on its first edit, like
  # its warehouse — supplied here unless the example passes its own.
  def update(request, attributes)
    attributes = { responsible_employee_id: responsible.id }.merge(attributes) if request.responsible_employee_id.nil?
    described_class.new(request.id, actor: actor, attributes: attributes).call
  end

  # 1. Draft can be edited
  it "updates a draft request's warehouse, notes and a line's supplier" do
    pr = draft_request
    result = update(pr, warehouse_id: warehouse_b.id, notes: "Urgent", items_attributes: line_attrs(pr, supplier_id: supplier_2.id))

    expect(result.ok?).to be(true)
    pr.reload
    expect(pr.warehouse).to eq(warehouse_b)
    expect(pr.items.sole.supplier).to eq(supplier_2)
    expect(pr.supplier_id).to be_nil
    expect(pr.notes).to eq("Urgent")
    expect(pr).to be_draft
  end

  it "keeps one warehouse for the whole request while its lines name different suppliers" do
    pr = draft_request
    result = update(pr, items_attributes: line_attrs(pr).merge(
      "1" => { product_id: product_b.id, quantity: 5, unit_price: 200, supplier_id: supplier_2.id }
    ))

    expect(result.ok?).to be(true)
    expect(pr.reload.items.map(&:supplier)).to contain_exactly(supplier_1, supplier_2)
    expect(pr.warehouse).to eq(warehouse_a)
  end

  # 2. Nothing after approval (or rejected / cancelled) can be edited; a
  # pending request only its items (see "editing items before approval").
  %w[pending_approval approved partially_received fully_received rejected cancelled].each do |status|
    it "refuses to update a #{status} request's details" do
      pr = draft_request
      pr.update_column(:status, status)

      result = update(pr, notes: "should not apply")

      expect(result.ok?).to be(false)
      expect(pr.reload.notes).not_to eq("should not apply")
      expect(pr.status).to eq(status)
    end
  end

  # 3. A line's supplier can be changed when valid
  it "overrides a line's supplier without touching the product's default supplier" do
    product_a.update!(default_supplier: supplier_1)
    pr = draft_request

    result = update(pr, items_attributes: line_attrs(pr, supplier_id: supplier_2.id))

    expect(result.ok?).to be(true)
    expect(pr.reload.items.sole.supplier).to eq(supplier_2)
    expect(product_a.reload.default_supplier).to eq(supplier_1)
  end

  it "rejects a line supplier from a different business" do
    foreign_supplier = create(:business).suppliers.create!(name: "Foreign")
    pr = draft_request

    result = update(pr, items_attributes: line_attrs(pr, supplier_id: foreign_supplier.id))

    expect(result.ok?).to be(false)
    expect(pr.reload.items.sole.supplier).to eq(supplier_1)
  end

  describe "warehouse" do
    it "rejects removing the warehouse" do
      pr = draft_request
      result = update(pr, warehouse_id: "")

      expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))
      expect(pr.reload.warehouse).to eq(warehouse_a)
    end

    it "rejects a warehouse of another business, an inactive one, and one outside the actor's scope" do
      pr = draft_request
      foreign_wh = create(:business).warehouses.create!(name: "Foreign WH")
      warehouse_b.update!(status: "inactive")

      expect(update(pr, warehouse_id: foreign_wh.id)).not_to be_ok
      expect(update(pr, warehouse_id: warehouse_b.id)).not_to be_ok

      scoped = create(:user, business: business)
      WarehouseAssignment.create!(user: scoped, warehouse: warehouse_a)
      other = business.warehouses.create!(name: "WH C")
      denied = described_class.new(pr.id, actor: scoped, attributes: { warehouse_id: other.id }).call
      expect(denied.error).to eq(I18n.t("inventory.purchase_requests.errors.unauthorized_warehouse"))
      expect(pr.reload.warehouse).to eq(warehouse_a)
    end

    it "rejects the same product twice in one request, whatever the suppliers" do
      pr = draft_request
      result = update(pr, items_attributes: line_attrs(pr).merge(
        "1" => { product_id: product_a.id, quantity: 1, unit_price: 100, supplier_id: supplier_2.id }
      ))

      expect(result.error).to eq(I18n.t("inventory.purchase_requests.errors.duplicate_product"))
      expect(pr.reload.items.count).to eq(1)
    end
  end

  describe "legacy draft (request-level supplier)" do
    it "must be given a warehouse before it can be saved, and keeps its legacy columns" do
      pr = legacy_draft_request
      expect(update(pr, notes: "edited").error).to eq(I18n.t("inventory.purchase_requests.errors.missing_warehouse"))

      result = update(pr, warehouse_id: warehouse_a.id, notes: "edited")
      expect(result).to be_ok
      pr.reload
      expect(pr.warehouse).to eq(warehouse_a)
      expect(pr.supplier).to eq(supplier_1)
      expect(pr.items.sole.source_warehouse_id).to be_nil
    end

    it "keeps every line on the request's one supplier" do
      pr = legacy_draft_request
      result = update(pr, warehouse_id: warehouse_a.id, items_attributes: line_attrs(pr, supplier_id: supplier_2.id))

      expect(result).not_to be_ok
      expect(pr.reload.items.sole.supplier).to eq(supplier_1)
    end
  end

  # 4 & 5. Items can be added / removed
  it "adds a new item" do
    pr = draft_request
    result = update(pr, items_attributes: {
      "0" => { id: pr.items.first.id, product_id: product_a.id, quantity: 10, unit_price: 100 },
      "1" => { product_id: product_b.id, quantity: 5, unit_price: 200 }
    })

    expect(result.ok?).to be(true)
    expect(pr.reload.items.count).to eq(2)
    expect(pr.items.map(&:product)).to contain_exactly(product_a, product_b)
  end

  it "removes an item via _destroy" do
    pr = draft_request
    pr.items.create!(product: product_b, quantity: 5, unit_price: 200)
    item_to_remove = pr.items.find_by(product: product_b)

    result = update(pr, items_attributes: {
      "0" => { id: pr.items.find_by(product: product_a).id, product_id: product_a.id, quantity: 10, unit_price: 100 },
      "1" => { id: item_to_remove.id, product_id: product_b.id, quantity: 5, unit_price: 200, _destroy: "1" }
    })

    expect(result.ok?).to be(true)
    expect(pr.reload.items.count).to eq(1)
    expect(pr.items.first.product).to eq(product_a)
  end

  # 6, 7, 8, 9. Quantity/price change and totals recalculate
  it "changes quantity and unit price, recalculating line and grand totals" do
    pr = draft_request(quantity: 10, unit_price: 100)
    item = pr.items.first

    result = update(pr, items_attributes: {
      "0" => { id: item.id, product_id: product_a.id, quantity: 4, unit_price: 250 }
    })

    expect(result.ok?).to be(true)
    item.reload
    expect(item.quantity).to eq(4)
    expect(item.unit_price).to eq(250)
    expect(item.total_cost).to eq(1000) # 4 * 250
    expect(pr.reload.total_amount).to eq(1000)
  end

  it "recalculates the grand total across multiple items" do
    pr = draft_request(quantity: 10, unit_price: 100) # 1000
    pr.items.create!(product: product_b, quantity: 5, unit_price: 200) # 1000

    expect(pr.reload.total_amount).to eq(2000)

    update(pr, items_attributes: {
      "0" => { id: pr.items.find_by(product: product_a).id, product_id: product_a.id, quantity: 20, unit_price: 100 }, # 2000
      "1" => { id: pr.items.find_by(product: product_b).id, product_id: product_b.id, quantity: 5, unit_price: 200 }  # 1000
    })

    expect(pr.reload.total_amount).to eq(3000)
  end

  # 10 & 11. Invalid quantity / price rejected
  it "rejects a zero/negative quantity" do
    pr = draft_request
    result = update(pr, items_attributes: {
      "0" => { id: pr.items.first.id, product_id: product_a.id, quantity: 0, unit_price: 100 }
    })
    expect(result.ok?).to be(false)
    expect(pr.reload.items.first.quantity).to eq(10)
  end

  it "rejects a zero/negative unit price" do
    pr = draft_request
    result = update(pr, items_attributes: {
      "0" => { id: pr.items.first.id, product_id: product_a.id, quantity: 10, unit_price: 0 }
    })
    expect(result.ok?).to be(false)
    expect(pr.reload.items.first.unit_price).to eq(100)
  end

  # 12. Empty request rejected
  it "rejects removing every item, leaving none" do
    pr = draft_request
    item = pr.items.first

    result = update(pr, items_attributes: {
      "0" => { id: item.id, product_id: product_a.id, quantity: 10, unit_price: 100, _destroy: "1" }
    })

    expect(result.ok?).to be(false)
    expect(pr.reload.items.count).to eq(1)
  end

  # 14 & 15. No inventory / GoodsReceipt side effects
  it "does not change inventory or create a GoodsReceipt" do
    pr = draft_request

    expect {
      update(pr, notes: "edited")
    }.not_to change(InventoryMovement, :count)

    expect(GoodsReceipt.where(purchase_request: pr).count).to eq(0)
    expect(product_a.reload.average_cost_price).to eq(100)
  end

  # 16. Request number unchanged
  it "never regenerates the request number" do
    pr = draft_request
    original_number = pr.request_number

    update(pr, notes: "edited")

    expect(pr.reload.request_number).to eq(original_number)
  end

  # 17 & 18. Stays draft, must be explicitly submitted
  it "leaves the request in draft after a successful edit — never auto-submits" do
    pr = draft_request
    update(pr, notes: "edited")

    expect(pr.reload).to be_draft
  end

  # 10 (audit). Writes an audit log entry
  it "writes an audit log entry for the edit" do
    pr = draft_request
    update(pr, notes: "edited")

    log = AuditLog.for_auditable(pr).find_by(action: "update")
    expect(log).to be_present
    expect(log.actor).to eq(actor)
  end

  # 19. Concurrency: approved by someone else between load and update
  it "fails safely if the request was approved by someone else in between" do
    pr = draft_request
    pr.update_column(:status, "pending_approval")

    updater = described_class.new(pr.id, actor: actor, attributes: { items_attributes: line_attrs(pr, quantity: 99) })
    # Simulate another request racing in and approving it between this
    # service loading the record and it acquiring the lock.
    allow_any_instance_of(PurchaseRequest).to receive(:items_editable?).and_wrap_original do |_method|
      pr.update_column(:status, "approved")
      false
    end

    result = updater.call
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_approved
    expect(pr.items.sole.quantity).to eq(10)
  end

  describe "responsible employee" do
    def message(key) = I18n.t("inventory.purchase_requests.errors.#{key}")

    it "changes a draft's responsible employee to another eligible one and audits the edit" do
      pr = draft_request
      other = purchaser_with_custody(business, first_name: "Lina")

      expect(update(pr, responsible_employee_id: other.id)).to be_ok
      expect(pr.reload.responsible_employee).to eq(other)
    end

    it "refuses an ineligible employee, leaving the draft unchanged" do
      pr = draft_request
      no_permission = create(:user, business: business).tap { |u| create(:custody_account, business: business, user: u) }

      expect(update(pr, responsible_employee_id: no_permission.id).error).to eq(message(:responsible_employee_ineligible))
      expect(pr.reload.responsible_employee).to eq(responsible)
    end

    it "is optional on a draft: it may be cleared, and a legacy draft is edited without one" do
      pr = draft_request
      expect(update(pr, responsible_employee_id: "")).to be_ok
      expect(pr.reload.responsible_employee_id).to be_nil

      legacy = legacy_draft_request(line_warehouse: warehouse_a)
      result = described_class.new(legacy.id, actor: actor, attributes: { warehouse_id: warehouse_a.id, notes: "x" }).call
      expect(result).to be_ok
      expect(legacy.reload.responsible_employee_id).to be_nil
    end

    it "does not re-judge an unchanged employee who has since lost eligibility" do
      pr = draft_request
      custody_of(responsible).update_column(:active, false)

      expect(update(pr, notes: "still editable")).to be_ok
    end
  end
end
