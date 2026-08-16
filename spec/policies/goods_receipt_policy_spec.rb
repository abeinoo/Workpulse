require "rails_helper"

RSpec.describe GoodsReceiptPolicy, type: :policy do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end

  let(:creator_role) { create(:permission_role, business: business, permissions: %w[view_inventory create_goods_receipts]) }
  let(:creator)       { create(:user, business: business, permission_role: creator_role) }
  let(:viewer_role)  { create(:permission_role, business: business, permissions: %w[view_inventory]) }
  let(:viewer)       { create(:user, business: business, permission_role: viewer_role) }

  def build_receipt(approval_status: "draft")
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r.update_column(:approval_status, approval_status)
    r.reload
  end

  describe "#cancel?" do
    it "lets a user with create_goods_receipts cancel a draft receipt" do
      receipt = build_receipt(approval_status: "draft")
      expect(described_class.new(creator, receipt).cancel?).to be true
    end

    it "lets a user with create_goods_receipts cancel a pending_approval receipt" do
      receipt = build_receipt(approval_status: "pending_approval")
      expect(described_class.new(creator, receipt).cancel?).to be true
    end

    it "does NOT let a plain viewer without create_goods_receipts cancel" do
      receipt = build_receipt(approval_status: "draft")
      expect(described_class.new(viewer, receipt).cancel?).to be false
    end

    it "does NOT allow cancel once the receipt is approved — only #void? applies there" do
      receipt = build_receipt(approval_status: "approved")
      expect(described_class.new(creator, receipt).cancel?).to be false
    end

    it "does NOT allow cancel of an already-voided receipt" do
      receipt = build_receipt(approval_status: "draft")
      receipt.update!(voided_at: Time.current, voided_by: creator, void_reason: "test")
      expect(described_class.new(creator, receipt).cancel?).to be false
    end
  end
end
