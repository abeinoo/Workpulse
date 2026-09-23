require "rails_helper"

RSpec.describe PurchaseRequestPolicy, type: :policy do
  let(:business) { create(:business) }

  let(:creator_role) { create(:permission_role, business: business, permissions: %w[view_inventory create_purchase_requests]) }
  let(:creator)       { create(:user, business: business, permission_role: creator_role) }
  let(:viewer_role)  { create(:permission_role, business: business, permissions: %w[view_inventory]) }
  let(:viewer)       { create(:user, business: business, permission_role: viewer_role) }
  let(:manager_role) { create(:permission_role, business: business, permissions: %w[view_inventory manage_inventory]) }
  let(:manager)       { create(:user, business: business, permission_role: manager_role) }
  let(:approver_role) { create(:permission_role, business: business, permissions: %w[view_inventory approve_purchase_requests]) }
  let(:approver)       { create(:user, business: business, permission_role: approver_role) }
  let(:receiver_role) { create(:permission_role, business: business, permissions: %w[view_inventory create_goods_receipts]) }
  let(:receiver)       { create(:user, business: business, permission_role: receiver_role) }
  let(:supplier)  { business.suppliers.create!(name: "Acme") }
  let(:product)   { business.products.create!(name: "Widget", sku: "W-1", average_cost_price: 100) }

  def request_with(status:)
    pr = business.purchase_requests.build(supplier: supplier, source: "low_stock_alert")
    pr.items.build(product: product, quantity: 10, unit_price: 100)
    pr.save!
    pr.update_column(:status, status)
    pr.reload
  end

  describe "#create?" do
    it "allows a user with create_purchase_requests" do
      expect(described_class.new(creator, PurchaseRequest).create?).to be true
    end

    it "allows a user with manage_inventory" do
      expect(described_class.new(manager, PurchaseRequest).create?).to be true
    end

    it "denies a user with only view_inventory" do
      expect(described_class.new(viewer, PurchaseRequest).create?).to be false
    end
  end

  describe "#index? / #show?" do
    it "allows any user with view_inventory" do
      expect(described_class.new(viewer, PurchaseRequest).index?).to be true
      expect(described_class.new(viewer, PurchaseRequest).show?).to be true
    end
  end

  describe "#submit_for_approval? / #destroy?" do
    it "allows the creator to submit/delete only while still draft" do
      draft = request_with(status: "draft")
      approved = request_with(status: "approved")

      expect(described_class.new(creator, draft).submit_for_approval?).to be true
      expect(described_class.new(creator, draft).destroy?).to be true
      expect(described_class.new(creator, approved).submit_for_approval?).to be false
      expect(described_class.new(creator, approved).destroy?).to be false
    end
  end

  describe "#update?" do
    it "allows the creator to edit only while still draft" do
      draft    = request_with(status: "draft")
      approved = request_with(status: "approved")
      pending  = request_with(status: "pending_approval")

      expect(described_class.new(creator, draft).update?).to be true
      expect(described_class.new(manager, draft).update?).to be true
      expect(described_class.new(creator, approved).update?).to be false
      expect(described_class.new(creator, pending).update?).to be false
      expect(described_class.new(viewer, draft).update?).to be false
    end
  end

  describe "#approve? / #reject?" do
    it "requires approve_purchase_requests (or manage_inventory) AND pending_approval status" do
      pending = request_with(status: "pending_approval")
      draft   = request_with(status: "draft")

      expect(described_class.new(approver, pending).approve?).to be true
      expect(described_class.new(approver, pending).reject?).to be true
      expect(described_class.new(creator, pending).approve?).to be false
      expect(described_class.new(approver, draft).approve?).to be false
    end
  end

  describe "#cancel?" do
    it "allows only while approved, and only with create_purchase_requests" do
      approved  = request_with(status: "approved")
      partial   = request_with(status: "partially_received")

      expect(described_class.new(creator, approved).cancel?).to be true
      expect(described_class.new(creator, partial).cancel?).to be false
      expect(described_class.new(viewer, approved).cancel?).to be false
    end
  end

  describe "#create_goods_receipt?" do
    it "requires create_goods_receipts (NOT create_purchase_requests) AND a receivable status" do
      approved           = request_with(status: "approved")
      partially_received = request_with(status: "partially_received")
      partially_closed    = request_with(status: "partially_closed")
      fully_received      = request_with(status: "fully_received")
      draft               = request_with(status: "draft")
      cancelled           = request_with(status: "cancelled")
      rejected            = request_with(status: "rejected")

      expect(described_class.new(receiver, approved).create_goods_receipt?).to be true
      expect(described_class.new(receiver, partially_received).create_goods_receipt?).to be true
      expect(described_class.new(receiver, partially_closed).create_goods_receipt?).to be false
      expect(described_class.new(receiver, fully_received).create_goods_receipt?).to be false
      expect(described_class.new(receiver, draft).create_goods_receipt?).to be false
      expect(described_class.new(receiver, cancelled).create_goods_receipt?).to be false
      expect(described_class.new(receiver, rejected).create_goods_receipt?).to be false

      # create_purchase_requests alone is NOT enough — this is a GoodsReceipt
      # creation action, gated by create_goods_receipts like any other receipt.
      expect(described_class.new(creator, approved).create_goods_receipt?).to be false
      expect(described_class.new(manager, approved).create_goods_receipt?).to be true
    end
  end

  describe "#close_remaining?" do
    it "requires approve_purchase_requests (or manage_inventory) AND partially_received status" do
      partially_received = request_with(status: "partially_received")
      approved            = request_with(status: "approved")
      fully_received       = request_with(status: "fully_received")
      partially_closed     = request_with(status: "partially_closed")

      expect(described_class.new(approver, partially_received).close_remaining?).to be true
      expect(described_class.new(manager, partially_received).close_remaining?).to be true
      expect(described_class.new(approver, approved).close_remaining?).to be false
      expect(described_class.new(approver, fully_received).close_remaining?).to be false
      expect(described_class.new(approver, partially_closed).close_remaining?).to be false

      # create_purchase_requests alone is NOT enough — this is an
      # approval-tier purchasing decision, not a plain create/manage-draft one.
      expect(described_class.new(creator, partially_received).close_remaining?).to be false
    end
  end
end
