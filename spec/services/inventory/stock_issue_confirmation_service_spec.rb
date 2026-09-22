require "rails_helper"

RSpec.describe Inventory::StockIssueConfirmationService, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  def receive_stock!(qty)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: qty, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def approved_issue(qty: 5)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: actor)
    i.items.build(product: product, quantity: qty)
    i.status = :approved
    i.approved_by = actor
    i.approved_at = Time.current
    i.save!
    i
  end

  def confirm(issue)
    described_class.new(stock_issue_id: issue.id, actor: actor).call
  end

  it "posts an OUT inventory movement per line, marks issued, records issued_by/at, and logs it — exactly at this step, never before" do
    receive_stock!(10)
    issue = approved_issue(qty: 5)

    result = confirm(issue)

    expect(result.ok?).to be(true)
    issue.reload
    expect(issue).to be_issued
    expect(issue.issued_by).to eq(actor)
    expect(issue.issued_at).to be_present
    expect(product.reload.current_stock).to eq(5)

    log = AuditLog.for_auditable(issue).find_by(action: "confirm")
    expect(log.actor).to eq(actor)
    expect(log.changes_json["status"]).to eq(%w[approved issued])
  end

  it "never deducts stock at approval time — only at confirmation" do
    receive_stock!(10)
    issue = approved_issue(qty: 5)
    expect(product.reload.current_stock).to eq(10)

    confirm(issue)
    expect(product.reload.current_stock).to eq(5)
  end

  describe "idempotency / double-confirmation protection" do
    it "refuses to confirm an already-issued issue and never double-deducts" do
      receive_stock!(10)
      issue = approved_issue(qty: 5)
      confirm(issue)

      result = confirm(issue)

      expect(result.ok?).to be(false)
      expect(product.reload.current_stock).to eq(5) # unchanged — not double-posted
      expect(issue.reload.inventory_movements.count).to eq(1)
    end
  end

  describe "approval gate" do
    %w[draft pending_approval rejected cancelled].each do |status|
      it "refuses to confirm while status is #{status}" do
        receive_stock!(10)
        issue = approved_issue(qty: 5)
        issue.update_column(:status, status)

        result = confirm(issue)

        expect(result.ok?).to be(false)
        expect(result.error).to eq(I18n.t("inventory.stock_issues.errors.not_approved"))
        expect(product.reload.current_stock).to eq(10)
      end
    end
  end

  describe "stock availability" do
    it "leaves the issue approved (not issued) and posts nothing when stock is insufficient" do
      receive_stock!(2)
      issue = approved_issue(qty: 5)

      result = confirm(issue)

      expect(result.ok?).to be(false)
      expect(issue.reload).to be_approved
      expect(product.reload.current_stock).to eq(2)
      expect(issue.inventory_movements.count).to eq(0)
    end
  end
end
