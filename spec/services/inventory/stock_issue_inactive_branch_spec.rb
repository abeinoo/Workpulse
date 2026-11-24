require "rails_helper"

# BUG-029 (D3), revised for warehouse-based Stock Issue authorization (Nov 24
# 2026): a Stock Issue no longer has a consuming branch, so a branch's status
# no longer gates it — the WAREHOUSE's does (RequiresActiveWarehouse +
# Inventory::IssueWarehouseReach). The issue's branch is only its cost
# attribution, recorded as it was.
#
# * an inactive branch: its warehouse's issues (and in-progress ones) carry on;
#   the historical branch attribution is kept;
# * an inactive warehouse: no new issue, no submission, approval or
#   confirmation from it (re-checked under lock), no import; rejecting,
#   cancelling and voiding stay available.
RSpec.describe "Stock issues at an inactive branch or warehouse (BUG-029, warehouse rule)", type: :model do
  let(:business)  { create(:business) }
  let(:requester) { stock_issue_user(business, :create_stock_issues) }
  let(:approver)  { stock_issue_user(business, :approve_stock_issues, :confirm_stock_issues, :cancel_stock_issues, :void_stock_issues) }
  let(:branch)    { business.branches.create!(name: "Nasr City", active: true) }
  let(:warehouse) { branch_warehouse_for(branch, name: "Main") }
  let(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end

  before do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(r).call
  end

  def issue_in(status)
    i = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current, created_by: requester)
    i.items.build(product: product, quantity: 2)
    i.status = status
    i.submitted_by = requester unless status == :draft
    i.approved_by  = approver if status == :approved
    i.save!
    i
  end

  def deactivate_branch    = branch.update_column(:active, false)
  def deactivate_warehouse = warehouse.update_column(:status, "inactive")

  describe "an inactive branch (no longer a gate)" do
    it "does not block a new issue from an active warehouse, which is attributed as before" do
      deactivate_branch
      issue = business.stock_issues.build(warehouse: warehouse, issued_on: Date.current, created_by: requester)
      issue.items.build(product: product, quantity: 1)

      expect(Inventory::StockIssueDraftService.new(issue, actor: requester).call).to be_ok
      expect(issue.reload.branch_id).to eq(branch.id)
    end

    it "lets an in-progress issue finish, keeping its recorded branch" do
      issue = issue_in(:pending_approval)
      deactivate_branch

      expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!).to be_ok
      expect(Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call).to be_ok
      expect(issue.reload).to have_attributes(status: "issued", branch_id: branch.id, warehouse_id: warehouse.id)
      expect(issue.inventory_movements.pluck(:branch_id)).to eq([ branch.id ])
    end
  end

  describe "an inactive warehouse" do
    it "refuses a new issue from it" do
      deactivate_warehouse
      issue = business.stock_issues.build(warehouse: warehouse, issued_on: Date.current, created_by: requester)
      issue.items.build(product: product, quantity: 1)

      result = nil
      expect { result = Inventory::StockIssueDraftService.new(issue, actor: requester).call }
        .not_to change { [ StockIssue.count, AuditLog.where(auditable_type: "StockIssue").count ] }
      expect(result).not_to be_ok
    end

    it "refuses submitting" do
      issue = issue_in(:draft)
      deactivate_warehouse

      expect(Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: requester).call).not_to be_ok
      expect(issue.reload).to be_draft
    end

    it "refuses approving, reserving nothing — and still allows rejecting" do
      issue = issue_in(:pending_approval)
      deactivate_warehouse

      result = Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).approve!
      expect(result.error).to eq(I18n.t("inventory.issue_warehouse.errors.inactive", warehouse: "Main"))
      expect(issue.reload).to be_pending_approval
      expect(AuditLog.where(auditable: issue, action: "approve")).to be_empty

      expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: approver).reject!(reason: "closed")).to be_ok
    end

    it "refuses confirming an issue approved before the deactivation, posting nothing — cancelling stays possible" do
      issue = issue_in(:approved)
      deactivate_warehouse

      expect(Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call).not_to be_ok
      expect(issue.reload).to be_approved
      expect(issue.inventory_movements).to be_empty

      expect(Inventory::StockIssueCancellation.new(stock_issue_id: issue.id, actor: approver, reason: "closed").call).to be_ok
    end

    it "still lets a posted issue be voided (its reversal returns stock to the original warehouse)" do
      issue = issue_in(:approved)
      Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: approver).call
      deactivate_warehouse

      expect(Inventory::DocumentVoider.new(issue.reload, user: approver, reason: "wrong").call).to be_ok
      expect(issue.reload).to be_voided
      expect(InventoryMovement.where(source: issue, direction: "in").pluck(:warehouse_id)).to eq([ warehouse.id ])
    end

    it "refuses a direct importer call, writing nothing" do
      deactivate_warehouse
      rows = [ { row_number: 2, "sku" => "SH-1", "quantity" => "1" } ]

      expect { Inventory::Imports::StockIssueImporter.new(business, rows, warehouse: warehouse, user: requester).call }
        .to raise_error(Inventory::WarehouseReach::Denied)
      expect(StockIssue.count).to eq(0)
      expect(StockIssueImportBatch.count).to eq(0)
    end
  end
end
