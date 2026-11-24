require "rails_helper"

# Warehouse Access hardening, Phase 2 (B): an inactive warehouse is refused on
# every inventory write path — at the model (RequiresActiveWarehouse) and at
# the movement ledger (InventoryMovement#warehouse_active_for_new_stock) —
# never only by dropdown filtering or a controller. Voids of history stay
# possible, and historical records are never touched.
RSpec.describe "Inactive warehouses on inventory write paths" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:branch)  { business.branches.create!(name: "Nasr City", active: true) }
  let!(:main_wh) { branch_warehouse_for(branch, name: "Main") } # Nasr City's own warehouse
  let!(:other_wh) { business.warehouses.create!(name: "Other") }
  let!(:product) do
    business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10)
  end
  let(:message) { I18n.t("errors.messages.warehouse_inactive", warehouse: main_wh.name) }

  def receive!(quantity = 10, warehouse: main_wh)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: quantity, unit_cost: 10)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
    receipt
  end

  def deactivate!(warehouse = main_wh) = warehouse.update_column(:status, "inactive")

  def base_errors(record)
    record.valid?
    record.errors[:base]
  end

  describe "Goods Receipts" do
    it "refuses a new receipt" do
      deactivate!
      receipt = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
      expect(base_errors(receipt)).to include(message)
    end

    it "refuses posting a draft whose warehouse was deactivated afterwards" do
      receipt = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
      receipt.items.build(product: product, quantity: 5, unit_cost: 10)
      receipt.save!
      deactivate!

      begin
        Inventory::GoodsReceiptPoster.new(receipt.reload).call
      rescue ActiveRecord::RecordInvalid
        # the ledger refused the movement; the poster's transaction rolled back
      end
      expect(InventoryMovement.where(warehouse: main_wh)).to be_empty
      expect(receipt.reload).to be_draft
    end

    it "refuses submitting a draft for approval" do
      receipt = business.goods_receipts.build(warehouse: main_wh, received_on: Date.current)
      receipt.items.build(product: product, quantity: 5, unit_cost: 10)
      receipt.save!
      deactivate!

      receipt.approval_status = "pending_approval"
      expect(base_errors(receipt)).to include(message)
    end
  end

  describe "Stock Issues" do
    it "refuses a new issue" do
      deactivate!
      issue = business.stock_issues.build(warehouse: main_wh, branch: branch, issued_on: Date.current)
      expect(base_errors(issue)).to include(message)
    end

    it "refuses confirming an issue approved before the warehouse was deactivated" do
      receive!
      issue = business.stock_issues.build(warehouse: main_wh, branch: branch, issued_on: Date.current)
      issue.items.build(product: product, quantity: 2)
      save_stock_issue_in_status!(issue, :approved)
      deactivate!

      result = nil
      expect { result = Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: owner).call }
        .not_to change(InventoryMovement, :count)
      expect(result).not_to be_ok
      expect(issue.reload).to be_approved
    end

    it "refuses a quick issue from an inactive warehouse — no fallback to another one" do
      receive!
      receive!(warehouse: other_wh)
      deactivate!
      result = Inventory::StockIssueQuickIssue.new(actor: owner, warehouse_id: main_wh.id,
                                                   product_id: product.id, quantity: "1",
                                                   reason: "internal_use").call
      expect(result).not_to be_ok
      expect(result.field_errors[:warehouse]).to eq(I18n.t("inventory.issue_warehouse.errors.not_allowed"))
      expect(StockIssue.count).to eq(0)
    end

    it "refuses an import batch" do
      deactivate!
      batch = StockIssueImportBatch.new(business: business, warehouse: main_wh)
      expect(base_errors(batch)).to include(message)
    end
  end

  describe "Stock Transfers" do
    it "refuses a transfer into an inactive warehouse" do
      receive!(warehouse: other_wh)
      deactivate!
      transfer = business.stock_transfers.build(source_warehouse: other_wh, destination_warehouse: main_wh,
                                                transferred_on: Date.current, created_by: owner)
      transfer.items.build(product: product, quantity: 1)

      expect { expect(Inventory::StockTransferPoster.new(transfer).call).not_to be_ok }
        .not_to change(InventoryMovement, :count)
    end

    it "refuses a transfer out of an inactive warehouse" do
      receive!
      deactivate!
      transfer = business.stock_transfers.build(source_warehouse: main_wh, destination_warehouse: other_wh,
                                                transferred_on: Date.current, created_by: owner)
      expect(base_errors(transfer)).to include(message)
    end
  end

  describe "Inventory Adjustments" do
    it "refuses an adjustment" do
      receive!
      deactivate!
      adjustment = business.stock_adjustments.build(warehouse: main_wh, adjusted_on: Date.current,
                                                    reason: "damaged", created_by: owner)
      adjustment.items.build(product: product, quantity_difference: -1)

      expect { expect(Inventory::AdjustmentPoster.new(adjustment).call).not_to be_ok }
        .not_to change(InventoryMovement, :count)
    end
  end

  describe "Stock Counts" do
    it "refuses a new count" do
      deactivate!
      result = Inventory::StockCountCreator.new(actor: owner, warehouse_id: main_wh.id, counted_on: Date.current).call
      expect(result).not_to be_ok
      expect(StockCount.count).to eq(0)
    end

    it "refuses moving a count forward" do
      count = StockCount.new(business: business, warehouse: main_wh, counted_on: Date.current, status: "draft")
      deactivate!
      count.status = "in_progress"
      expect(base_errors(count)).to include(message)
    end
  end

  describe "Purchase Requests" do
    it "refuses a request for an inactive destination warehouse" do
      deactivate!
      expect(base_errors(PurchaseRequest.new(business: business, warehouse: main_wh))).to include(message)
    end

    it "refuses a line sourced from an inactive warehouse" do
      deactivate!
      expect(base_errors(PurchaseRequestItem.new(source_warehouse: main_wh))).to include(message)
    end
  end

  describe "Laundry consumption and every other stock movement (the ledger)" do
    it "refuses any new movement in an inactive warehouse" do
      deactivate!
      movement = InventoryMovement.new(business: business, product: product, warehouse: main_wh, direction: :out,
                                       reason: :laundry_consumption, quantity: 1, unit_cost: 10, occurred_on: Date.current)
      expect(base_errors(movement)).to include(message)
    end

    it "accepts the compensating reversal of a void" do
      deactivate!
      movement = InventoryMovement.new(business: business, product: product, warehouse: main_wh, direction: :out,
                                       reason: :reversal, quantity: 1, unit_cost: 10, occurred_on: Date.current)
      expect(base_errors(movement)).not_to include(message)
    end
  end

  describe "history (13)" do
    it "still voids a receipt posted before the deactivation, leaving its original movements unchanged" do
      receipt  = receive!
      original = InventoryMovement.where(source: receipt).map(&:attributes)
      deactivate!

      result = Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: owner, reason: "Wrong warehouse").call

      expect(result).to be_ok
      expect(InventoryMovement.where(source: receipt, reason: "goods_receipt").map(&:attributes)).to eq(original)
      expect(InventoryMovement.where(source: receipt, reason: "reversal").count).to eq(1)
    end

    it "does not re-validate an existing document for an unrelated change" do
      receipt = receive!
      deactivate!
      receipt.reload.notes = "Annotated after deactivation"
      expect(base_errors(receipt)).not_to include(message)
    end
  end
end
