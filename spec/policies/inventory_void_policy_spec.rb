require "rails_helper"

RSpec.describe "Inventory void & adjustment policies" do
  let(:business) { create(:business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer)         { user_with("view_inventory") }
  let(:manager)        { user_with("view_inventory", "manage_inventory") }
  let(:void_mgr)       { user_with("view_inventory", "void_goods_receipts") }
  let(:creator)        { user_with("view_inventory", "create_goods_receipts") }
  let(:approver)       { user_with("view_inventory", "approve_goods_receipts") }
  let(:confirmer)      { user_with("view_inventory", "confirm_goods_receipts") }

  describe GoodsReceiptPolicy do
    it "gates create behind manage_inventory or create_goods_receipts (manage_stock_receipts alone is no longer enough)" do
      legacy = user_with("view_inventory", "manage_stock_receipts")
      expect(GoodsReceiptPolicy.new(viewer, GoodsReceipt).create?).to be(false)
      expect(GoodsReceiptPolicy.new(legacy, GoodsReceipt).create?).to be(false)
      expect(GoodsReceiptPolicy.new(creator, GoodsReceipt).create?).to be(true)
      expect(GoodsReceiptPolicy.new(manager, GoodsReceipt).create?).to be(true)
    end

    it "allows void only for managers / dedicated void permission" do
      legacy = user_with("view_inventory", "manage_stock_receipts")
      expect(GoodsReceiptPolicy.new(viewer, GoodsReceipt).void?).to be(false)
      expect(GoodsReceiptPolicy.new(legacy, GoodsReceipt).void?).to be(false)
      expect(GoodsReceiptPolicy.new(manager, GoodsReceipt).void?).to be(true)
      expect(GoodsReceiptPolicy.new(void_mgr, GoodsReceipt).void?).to be(true)
    end

    it "denies void for a draft receipt even with permission, allows once confirmed" do
      warehouse = business.warehouses.create!(name: "Main")
      draft = business.goods_receipts.create!(warehouse: warehouse, received_on: Date.current,
                                              items_attributes: { "0" => { product_id: business.products.create!(name: "P", sku: "P-1").id, quantity: 1, unit_cost: 1 } })
      expect(GoodsReceiptPolicy.new(manager, draft).void?).to be(false)

      draft.update_column(:status, "confirmed")
      expect(GoodsReceiptPolicy.new(manager, draft).void?).to be(true)
    end

    it "gates confirm behind manage_inventory or confirm_goods_receipts" do
      expect(GoodsReceiptPolicy.new(viewer, GoodsReceipt).confirm?).to be(false)
      expect(GoodsReceiptPolicy.new(void_mgr, GoodsReceipt).confirm?).to be(false)
      expect(GoodsReceiptPolicy.new(confirmer, GoodsReceipt).confirm?).to be(true)
      expect(GoodsReceiptPolicy.new(manager, GoodsReceipt).confirm?).to be(true)
    end

    it "gates approve/reject behind manage_inventory or approve_goods_receipts, only while pending_approval" do
      warehouse = business.warehouses.create!(name: "Main")
      pending = business.goods_receipts.create!(warehouse: warehouse, received_on: Date.current, approval_status: "pending_approval",
                                                items_attributes: { "0" => { product_id: business.products.create!(name: "P2", sku: "P-2").id, quantity: 1, unit_cost: 1 } })
      expect(GoodsReceiptPolicy.new(viewer, pending).approve?).to be(false)
      expect(GoodsReceiptPolicy.new(creator, pending).approve?).to be(false)
      expect(GoodsReceiptPolicy.new(approver, pending).approve?).to be(true)
      expect(GoodsReceiptPolicy.new(approver, pending).reject?).to be(true)
      expect(GoodsReceiptPolicy.new(manager, pending).approve?).to be(true)

      pending.update_column(:approval_status, "draft")
      expect(GoodsReceiptPolicy.new(approver, pending).approve?).to be(false)
    end

    it "allows update/submit only while draft or rejected, blocks once pending_approval or approved" do
      warehouse = business.warehouses.create!(name: "Main")
      receipt = business.goods_receipts.create!(warehouse: warehouse, received_on: Date.current,
                                                items_attributes: { "0" => { product_id: business.products.create!(name: "P3", sku: "P-3").id, quantity: 1, unit_cost: 1 } })
      expect(GoodsReceiptPolicy.new(creator, receipt).update?).to be(true)
      expect(GoodsReceiptPolicy.new(creator, receipt).submit_for_approval?).to be(true)

      receipt.update_column(:approval_status, "rejected")
      expect(GoodsReceiptPolicy.new(creator, receipt).update?).to be(true)

      receipt.update_column(:approval_status, "pending_approval")
      expect(GoodsReceiptPolicy.new(creator, receipt).update?).to be(false)

      receipt.update_column(:approval_status, "approved")
      expect(GoodsReceiptPolicy.new(creator, receipt).update?).to be(false)
    end
  end

  describe StockIssuePolicy do
    it "gates void behind manage permissions" do
      expect(StockIssuePolicy.new(viewer, StockIssue).void?).to be(false)
      expect(StockIssuePolicy.new(manager, StockIssue).void?).to be(true)
    end
  end

  describe StockTransferPolicy do
    it "gates void behind manage permissions" do
      expect(StockTransferPolicy.new(viewer, StockTransfer).void?).to be(false)
      expect(StockTransferPolicy.new(manager, StockTransfer).void?).to be(true)
    end
  end

  describe StockAdjustmentPolicy do
    it "allows view for viewers, create/void only for managers" do
      expect(StockAdjustmentPolicy.new(viewer, StockAdjustment).index?).to be(true)
      expect(StockAdjustmentPolicy.new(viewer, StockAdjustment).create?).to be(false)
      expect(StockAdjustmentPolicy.new(viewer, StockAdjustment).void?).to be(false)
      expect(StockAdjustmentPolicy.new(manager, StockAdjustment).create?).to be(true)
      expect(StockAdjustmentPolicy.new(manager, StockAdjustment).void?).to be(true)
    end
  end
end
