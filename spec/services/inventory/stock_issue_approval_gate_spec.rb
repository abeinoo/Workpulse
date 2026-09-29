require "rails_helper"

# The approval gate: a stock issue deducts stock ONLY once it is approved and
# then confirmed. Inventory::StockIssuePoster is the single place stock moves
# for a stock issue, and it — plus StockIssue's own validation — refuses
# anything that isn't approved, whatever the caller or creation path.
RSpec.describe "Stock issue approval gate" do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10,
                              reorder_level: 8)
  end

  let(:importer_user) { create(:user, business: business) }
  let(:approver_role) { create(:permission_role, business: business, permissions: %w[view_inventory approve_stock_issues]) }
  let(:approver)      { create(:user, business: business, permission_role: approver_role) }
  let(:confirmer_role) { create(:permission_role, business: business, permissions: %w[view_inventory confirm_stock_issues]) }
  let(:confirmer)      { create(:user, business: business, permission_role: confirmer_role) }

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def import_issue(qty: 5)
    rows = [ { :row_number => 2, "sku" => product.sku, "quantity" => qty.to_s } ]
    Inventory::Imports::StockIssueImporter.new(business, rows, warehouse: warehouse, branch: branch,
                                               user: importer_user).call.issue
  end

  def issue_in(status, qty: 5)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
    i.items.build(product: product, quantity: qty)
    save_stock_issue_in_status!(i, status)
  end

  describe Inventory::StockIssuePoster do
    %w[draft pending_approval rejected cancelled].each do |status|
      it "refuses to post a #{status} issue — no movement, no deduction, clear error" do
        issue = issue_in(status)

        result = nil
        expect { result = described_class.new(issue).call }.not_to change(InventoryMovement, :count)

        expect(result).not_to be_ok
        expect(issue.errors.details[:base]).to include(error: :not_approved)
        expect(issue.errors.full_messages).to include(I18n.t("activerecord.errors.models.stock_issue.attributes.base.not_approved"))
        expect(issue.reload.status).to eq(status)
        expect(product.stock_in(warehouse)).to eq(10)
      end
    end

    it "refuses an imported issue straight out of the import" do
      issue = import_issue

      expect(described_class.new(issue).call).not_to be_ok
      expect(issue.reload).to be_pending_approval
      expect(product.stock_in(warehouse)).to eq(10)
    end

    it "posts an approved issue" do
      issue = issue_in(:approved)

      expect(described_class.new(issue).call).to be_ok
      expect(issue.reload).to be_issued
      expect(product.stock_in(warehouse)).to eq(5)
    end

    it "refuses a brand-new record merely built with status approved — approval must already be persisted" do
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :approved)
      issue.items.build(product: product, quantity: 5)

      expect { described_class.new(issue).call }.not_to change(InventoryMovement, :count)
      expect(issue).not_to be_persisted
    end
  end

  describe "StockIssue model invariant" do
    it "refuses any save that sets status to issued from anything but approved" do
      issue = issue_in(:pending_approval)

      expect(issue.update(status: :issued)).to be false
      expect(issue.errors.details[:base]).to include(error: :not_approved)
      expect(issue.reload).to be_pending_approval
    end

    it "refuses creating a record directly as issued" do
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, status: :issued)
      issue.items.build(product: product, quantity: 1)

      expect(issue.save).to be false
      expect(issue.errors.details[:base]).to include(error: :not_approved)
    end
  end

  describe "imported issue through the existing workflow" do
    it "requires approval, then deducts stock only at confirmation" do
      issue = import_issue
      expect(issue).to be_pending_approval

      confirm = Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: confirmer).call
      expect(confirm).not_to be_ok
      expect(confirm.error).to eq(I18n.t("inventory.stock_issues.errors.not_approved"))
      expect(product.stock_in(warehouse)).to eq(10)

      expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!).to be_ok
      expect(issue.reload).to be_approved
      expect(product.stock_in(warehouse)).to eq(10) # approval alone never deducts

      expect(Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: confirmer).call).to be_ok
      expect(issue.reload).to be_issued
      expect(product.stock_in(warehouse)).to eq(5)
      expect(issue.inventory_movements.sole).to have_attributes(direction: "out", reason: "stock_issue", quantity: 5)
    end

    it "keeps the self-approval rule: the importing user cannot approve their own import" do
      importer_user.update!(permission_role: approver_role)
      issue = import_issue

      result = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: importer_user).approve!

      expect(result).not_to be_ok
      expect(issue.reload).to be_pending_approval
    end
  end

  describe "pending issues never affect stock figures or reports" do
    let!(:pending) { import_issue(qty: 5) }
    let!(:approved) { issue_in(:approved, qty: 3) }

    it "current stock and per-warehouse stock ignore them" do
      expect(product.current_stock).to eq(10)
      expect(product.stock_in(warehouse)).to eq(10)
    end

    it "low-stock calculations ignore them" do
      # 10 on hand, reorder level 8: an unposted 5 + 3 would push it below.
      expect(Product.low_stock).not_to include(product)
      expect(product.low_stock?).to be false
    end

    it "the consumption ledger, movements report and branch comparison ignore them" do
      expect(Inventory::ConsumptionLedger.new(business).relation).to be_empty
      expect(Inventory::ConsumptionLedger.new(business).cost_by_branch).to be_empty
      expect(Inventory::Reports::Movements.new(business).rows.map(&:reason)).not_to include("stock_issue")
      expect(InventoryMovement.where(source: [ pending, approved ])).to be_empty
    end

    it "only a confirmed issue reaches the ledger" do
      Inventory::StockIssueConfirmationService.new(stock_issue_id: approved.id, actor: confirmer).call

      expect(Inventory::ConsumptionLedger.new(business).relation.pluck(:source_id)).to eq([ approved.id ])
      expect(product.current_stock).to eq(7)
    end
  end
end
