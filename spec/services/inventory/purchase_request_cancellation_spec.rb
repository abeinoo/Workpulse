require "rails_helper"

RSpec.describe Inventory::PurchaseRequestCancellation, type: :model do
  let(:business) { create(:business) }
  let(:actor)    { create(:user, :super_admin, business: business) }
  let(:supplier) { business.suppliers.create!(name: "Acme") }
  let(:product)  { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }

  def approved_request
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
    pr.items.build(product: product, quantity: 10, unit_price: 100)
    pr.save!
    pr.update_column(:status, "approved")
    pr.reload
  end

  it "cancels an approved request with a reason and logs it" do
    request = approved_request
    result = described_class.new(purchase_request_id: request.id, actor: actor, reason: "No longer needed").call

    expect(result.ok?).to be(true)
    expect(request.reload).to be_cancelled
    expect(request.cancellation_reason).to eq("No longer needed")
    log = AuditLog.for_auditable(request).find_by(action: "cancel")
    expect(log).to be_present
  end

  it "requires a reason" do
    request = approved_request
    result = described_class.new(purchase_request_id: request.id, actor: actor, reason: "").call

    expect(result.ok?).to be(false)
    expect(request.reload).to be_approved
  end

  it "refuses to cancel a draft request" do
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
    pr.items.build(product: product, quantity: 10, unit_price: 100)
    pr.save!

    result = described_class.new(purchase_request_id: pr.id, actor: actor, reason: "test").call
    expect(result.ok?).to be(false)
    expect(pr.reload).to be_draft
  end

  it "refuses to cancel a request that has already started receiving" do
    request = approved_request
    request.update_column(:status, "partially_received")

    result = described_class.new(purchase_request_id: request.id, actor: actor, reason: "test").call
    expect(result.ok?).to be(false)
    expect(request.reload).to be_partially_received
  end
end
