require "rails_helper"

RSpec.describe Inventory::StockIssueCancellation, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  def issue(status:)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: actor)
    i.items.build(product: product, quantity: 1) unless status == "draft"
    save_stock_issue_in_status!(i, status)
  end

  def cancel(issue, reason: "no longer needed")
    described_class.new(stock_issue_id: issue.id, actor: actor, reason: reason).call
  end

  %w[draft approved].each do |status|
    it "cancels a #{status} issue: records cancelled_by/at/reason and logs it" do
      record = issue(status: status)

      result = cancel(record, reason: "duplicate entry")

      expect(result.ok?).to be(true)
      record.reload
      expect(record).to be_cancelled
      expect(record.cancelled_by).to eq(actor)
      expect(record.cancelled_at).to be_present
      expect(record.cancellation_reason).to eq("duplicate entry")

      log = AuditLog.for_auditable(record).find_by(action: "cancel")
      expect(log.metadata["reason"]).to eq("duplicate entry")
    end
  end

  it "requires a non-blank reason" do
    record = issue(status: "draft")
    result = cancel(record, reason: "  ")
    expect(result.ok?).to be(false)
    expect(record.reload).to be_draft
  end

  %w[pending_approval rejected issued cancelled].each do |status|
    it "refuses to cancel while status is #{status}" do
      record = issue(status: status)
      result = cancel(record)
      expect(result.ok?).to be(false)
      expect(record.reload.status).to eq(status)
    end
  end

  it "never touches inventory" do
    record = issue(status: "approved")
    cancel(record)
    expect(record.inventory_movements.count).to eq(0)
  end
end
