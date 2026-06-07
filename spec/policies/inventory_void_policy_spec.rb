require "rails_helper"

RSpec.describe "Inventory void & adjustment policies" do
  let(:business) { create(:business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:viewer)         { user_with("view_inventory") }
  let(:manager)        { user_with("view_inventory", "manage_inventory") }
  let(:receipt_mgr)    { user_with("view_inventory", "manage_stock_receipts") }

  describe GoodsReceiptPolicy do
    it "allows void only for managers / receipt managers" do
      expect(GoodsReceiptPolicy.new(viewer, GoodsReceipt).void?).to be(false)
      expect(GoodsReceiptPolicy.new(manager, GoodsReceipt).void?).to be(true)
      expect(GoodsReceiptPolicy.new(receipt_mgr, GoodsReceipt).void?).to be(true)
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
