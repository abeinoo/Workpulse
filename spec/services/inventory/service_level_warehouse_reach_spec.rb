require "rails_helper"

# Warehouse Access hardening, Phase 2 (C): the posting / approval /
# confirmation services enforce warehouse reach and business scope
# themselves (Inventory::WarehouseReach — the controllers' own rule), so a
# service called outside its controller is never a bypass. Each example acts
# as a user with every inventory permission but reach to OTHER only, on a
# document in MAIN.
RSpec.describe "Service-level warehouse reach" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { business.branches.create!(name: "Nasr City", active: true) }
  let!(:main_wh)  { branch_warehouse_for(branch, name: "Main") } # the branch's own warehouse
  let!(:other_wh) { business.warehouses.create!(name: "Other") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let(:denied) { I18n.t("inventory.errors.warehouse_not_accessible") }

  # Every inventory permission, reach limited to OTHER by an explicit
  # assignment (the legacy rule and the fail-closed rule agree on this).
  let(:outsider) do
    user_with_stock_permissions(business, *PermissionRole::PERMISSION_GROUPS.values_at(:inventory, :stock_issues).flatten
                                            .reject { |p| p == "access_all_warehouses" })
      .tap { |u| WarehouseAssignment.create!(user: u, warehouse: other_wh) }
  end

  before do
    receipt = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
    receipt.items.build(product: product, quantity: 10, unit_cost: 10)
    Inventory::GoodsReceiptPoster.new(receipt).call
  end

  def draft_issue(status = :draft)
    issue = business.stock_issues.build(warehouse: main_wh, branch: branch, issued_on: Date.current, created_by: owner)
    issue.items.build(product: product, quantity: 1)
    save_stock_issue_in_status!(issue, status)
  end

  describe Inventory::WarehouseReach do
    it "passes the owner for every warehouse of their business, never another business's" do
      foreign = create(:business).warehouses.create!(name: "Foreign")
      expect(described_class.permits?(owner, main_wh, other_wh)).to be(true)
      expect(described_class.permits?(owner, foreign)).to be(false)
    end

    it "passes a scoped user only inside their reach" do
      expect(described_class.permits?(outsider, other_wh)).to be(true)
      expect(described_class.permits?(outsider, main_wh)).to be(false)
      expect(described_class.permits?(outsider, other_wh, main_wh)).to be(false)
    end

    it "fails closed with no actor or no warehouse" do
      expect(described_class.permits?(nil, main_wh)).to be(false)
      expect(described_class.permits?(owner)).to be(false)
      expect(described_class.permits?(owner, allow_none: true)).to be(true)
      expect(described_class.permits?(outsider, allow_none: true)).to be(false)
    end
  end

  describe "Stock Issues" do
    it "refuses a draft" do
      issue = business.stock_issues.build(warehouse: main_wh, branch: branch, issued_on: Date.current)
      issue.items.build(product: product, quantity: 1)
      expect { expect(Inventory::StockIssueDraftService.new(issue, actor: outsider).call).not_to be_ok }
        .not_to change(StockIssue, :count)
    end

    it "refuses submission, approval, rejection, confirmation and cancellation" do
      expect(Inventory::StockIssueSubmission.new(stock_issue_id: draft_issue.id, actor: outsider).call.error).to eq(denied)

      pending = draft_issue(:pending_approval)
      approval = Inventory::StockIssueApproval.new(stock_issue_id: pending.id, actor: outsider)
      expect(approval.approve!.error).to eq(denied)
      expect(approval.reject!(reason: "no").error).to eq(denied)

      approved = draft_issue(:approved)
      expect { Inventory::StockIssueConfirmationService.new(stock_issue_id: approved.id, actor: outsider).call }
        .not_to change(InventoryMovement, :count)
      expect(Inventory::StockIssueCancellation.new(stock_issue_id: approved.id, actor: outsider, reason: "x").call.error)
        .to eq(denied)
      expect(approved.reload).to be_approved
    end

    it "refuses an edit, and an edit moving an issue into an unreachable warehouse" do
      expect(Inventory::StockIssueEditor.new(stock_issue_id: draft_issue.id, actor: outsider, attributes: {}).call.error)
        .to eq(denied)

      # A submitted warehouse is never followed: the source warehouse is not
      # editable (branch-warehouse rule), so an edit cannot move the issue.
      mine = business.stock_issues.build(warehouse: other_wh, branch: branch, issued_on: Date.current, created_by: outsider)
      mine.save!
      Inventory::StockIssueEditor.new(stock_issue_id: mine.id, actor: outsider, attributes: { warehouse_id: main_wh.id }).call
      expect(mine.reload.warehouse).to eq(other_wh)
    end

    it "refuses a void" do
      issued = draft_issue(:issued)
      expect { Inventory::DocumentVoider.new(issued, user: outsider, reason: "x").call }
        .not_to change(InventoryMovement, :count)
      expect(issued.reload.voided_at).to be_nil
    end

    it "refuses an import into an unreachable warehouse" do
      importer = Inventory::Imports::StockIssueImporter.new(business, [], warehouse: main_wh, user: outsider)
      expect { importer.call }.to raise_error(Inventory::WarehouseReach::Denied)
    end
  end

  describe "Goods Receipts" do
    let(:draft_receipt) do
      business.goods_receipts.build(warehouse: main_wh, received_on: Date.current).tap do |r|
        r.items.build(product: product, quantity: 1, unit_cost: 10)
        r.save!
      end
    end

    it "refuses a draft, submission, approval, confirmation, posting and void" do
      fresh = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
      fresh.items.build(product: product, quantity: 1, unit_cost: 10)
      expect(Inventory::GoodsReceiptDraftService.new(fresh, actor: outsider).call).not_to be_ok

      approval = Inventory::GoodsReceiptApproval.new(goods_receipt_id: draft_receipt.id, actor: outsider)
      expect(approval.submit!.error).to eq(denied)
      expect(approval.approve!.error).to eq(denied)
      expect(Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: draft_receipt.id, actor: outsider).call.error)
        .to eq(denied)
      expect { expect(Inventory::GoodsReceiptPoster.new(draft_receipt, actor: outsider).call).not_to be_ok }
        .not_to change(InventoryMovement, :count)
      expect(Inventory::GoodsReceiptVoider.new(goods_receipt_id: draft_receipt.id, actor: outsider, reason: "x").call.error)
        .to eq(denied)
      expect(draft_receipt.reload.voided_at).to be_nil
    end
  end

  describe "Stock Transfers and Adjustments" do
    it "refuses a transfer touching an unreachable warehouse — by the explicit actor or the creator" do
      transfer = business.stock_transfers.build(source_warehouse: main_wh, destination_warehouse: other_wh,
                                                transferred_on: Date.current, created_by: outsider)
      transfer.items.build(product: product, quantity: 1)

      expect { expect(Inventory::StockTransferPoster.new(transfer).call).not_to be_ok }
        .not_to change(InventoryMovement, :count)
      expect(transfer.errors[:base]).to include(denied)
    end

    it "refuses an adjustment in an unreachable warehouse" do
      adjustment = business.stock_adjustments.build(warehouse: main_wh, adjusted_on: Date.current, reason: "damaged")
      adjustment.items.build(product: product, quantity_difference: -1)

      expect { expect(Inventory::AdjustmentPoster.new(adjustment, actor: outsider).call).not_to be_ok }
        .not_to change(InventoryMovement, :count)
    end
  end

  describe "Stock Counts" do
    it "refuses creating, recording, completing and approving a count" do
      expect(Inventory::StockCountCreator.new(actor: outsider, warehouse_id: main_wh.id, counted_on: Date.current).call.error)
        .to eq(denied)

      count = Inventory::StockCountCreator.new(actor: owner, warehouse_id: main_wh.id, counted_on: Date.current).call.count
      expect(Inventory::StockCountRecorder.new(stock_count_id: count.id, actor: outsider, entries: {}).call.error).to eq(denied)
      expect(Inventory::StockCountCompletion.new(stock_count_id: count.id, actor: outsider).call.error).to eq(denied)
      expect(Inventory::StockCountApprover.new(stock_count_id: count.id, actor: outsider).call.error).to eq(denied)
    end
  end

  describe "Purchase Requests" do
    it "does not find a request outside the actor's warehouse scope (as PurchaseRequestApproval)" do
      request = business.purchase_requests.create!(warehouse: main_wh, created_by: owner,
                                                   items_attributes: [ { product_id: product.id, quantity: 1, unit_price: 10 } ])

      expect { Inventory::PurchaseRequestCancellation.new(purchase_request_id: request.id, actor: outsider, reason: "x").call }
        .to raise_error(ActiveRecord::RecordNotFound)
      expect { Inventory::PurchaseRequestUpdater.new(request.id, actor: outsider, attributes: {}).call }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "Branch supply" do
    it "refuses linking a branch to an unreachable warehouse" do
      result = Inventory::WarehouseSupplyAssigner.new(branch_id: branch.id, warehouse_id: main_wh.id,
                                                      active: true, actor: outsider).call
      expect(result.error).to eq(denied)
      expect(WarehouseBranchSupply.count).to eq(0)
    end
  end

  describe "cross-business" do
    it "never finds another business's document" do
      stranger = create(:user, :owner, business: create(:business))
      expect { Inventory::StockIssueSubmission.new(stock_issue_id: draft_issue.id, actor: stranger).call }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
