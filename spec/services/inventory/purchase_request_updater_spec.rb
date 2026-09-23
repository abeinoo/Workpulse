require "rails_helper"

RSpec.describe Inventory::PurchaseRequestUpdater, type: :model do
  let(:business)    { create(:business) }
  let(:actor)       { create(:user, :super_admin, business: business) }
  let(:supplier_1)  { business.suppliers.create!(name: "Supplier 1") }
  let(:supplier_2)  { business.suppliers.create!(name: "Supplier 2") }
  let(:product_a)   { business.products.create!(name: "Product A", sku: "A-1", average_cost_price: 100) }
  let(:product_b)   { business.products.create!(name: "Product B", sku: "B-1", average_cost_price: 200) }

  def draft_request(quantity: 10, unit_price: 100, supplier: supplier_1)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert", created_by: actor)
    pr.items.build(product: product_a, quantity: quantity, unit_price: unit_price)
    pr.save!
    pr
  end

  def update(request, attributes)
    described_class.new(request.id, actor: actor, attributes: attributes).call
  end

  # 1. Draft can be edited
  it "updates a draft request's supplier and notes" do
    pr = draft_request
    result = update(pr, supplier_id: supplier_2.id, notes: "Urgent")

    expect(result.ok?).to be(true)
    expect(pr.reload.supplier_id).to eq(supplier_2.id)
    expect(pr.notes).to eq("Urgent")
    expect(pr).to be_draft
  end

  # 2. Non-draft cannot be edited (each non-draft status)
  %w[pending_approval approved partially_received fully_received rejected cancelled].each do |status|
    it "refuses to update a #{status} request" do
      pr = draft_request
      pr.update_column(:status, status)

      result = update(pr, notes: "should not apply")

      expect(result.ok?).to be(false)
      expect(pr.reload.notes).not_to eq("should not apply")
      expect(pr.status).to eq(status)
    end
  end

  # 3. Supplier can be changed when valid
  it "allows changing the supplier without touching Product#default_supplier_id" do
    pr = draft_request
    expect(product_a.default_supplier_id).to be_nil

    update(pr, supplier_id: supplier_2.id)

    expect(pr.reload.supplier_id).to eq(supplier_2.id)
    expect(product_a.reload.default_supplier_id).to be_nil
  end

  it "rejects a supplier from a different business" do
    other_business = create(:business)
    foreign_supplier = other_business.suppliers.create!(name: "Foreign")
    pr = draft_request

    result = update(pr, supplier_id: foreign_supplier.id)
    expect(result.ok?).to be(false)
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

  # 19. Concurrency: state changes from draft to submitted between load and update
  it "fails safely if the request was submitted for approval by someone else in between" do
    pr = draft_request

    updater = described_class.new(pr.id, actor: actor, attributes: { notes: "edited" })
    # Simulate another request racing in and submitting it for approval
    # between this service loading the record and it acquiring the lock.
    allow_any_instance_of(PurchaseRequest).to receive(:draft?).and_wrap_original do |method|
      pr.update_column(:status, "pending_approval")
      false
    end

    result = updater.call
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_pending_approval
    expect(pr.notes).not_to eq("edited")
  end
end
