require "rails_helper"

RSpec.describe Inventory::GoodsReceiptApproval, type: :model do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :super_admin, business: business) }
  let(:requester) { create(:user, business: business) }
  let(:approver)  { create(:user, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0) }

  def draft_receipt(created_by: requester)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, created_by: created_by)
    r.items.build(product: product, quantity: 1, unit_cost: 100)
    r.save!
    r
  end

  def approval_for(receipt, actor:)
    described_class.new(goods_receipt_id: receipt.id, actor: actor)
  end

  describe "#submit!" do
    it "moves draft to pending_approval and logs the transition" do
      receipt = draft_receipt
      result = approval_for(receipt, actor: requester).submit!

      expect(result.ok?).to be(true)
      expect(receipt.reload).to be_approval_pending_approval
      log = AuditLog.for_auditable(receipt).find_by(action: "submit_for_approval")
      expect(log).to be_present
      expect(log.actor).to eq(requester)
      expect(log.changes_json["approval_status"]).to eq(%w[draft pending_approval])
    end

    it "moves rejected back to pending_approval and clears the rejection reason" do
      receipt = draft_receipt
      receipt.update_columns(approval_status: "rejected", rejection_reason: "wrong price")

      result = approval_for(receipt, actor: requester).submit!

      expect(result.ok?).to be(true)
      expect(receipt.reload).to be_approval_pending_approval
      expect(receipt.rejection_reason).to be_nil
    end

    it "refuses to submit an already-pending receipt" do
      receipt = draft_receipt
      receipt.update_column(:approval_status, "pending_approval")

      result = approval_for(receipt, actor: requester).submit!
      expect(result.ok?).to be(false)
    end
  end

  describe "#approve!" do
    it "moves pending_approval to approved, records who/when, and logs it" do
      receipt = draft_receipt
      receipt.update_column(:approval_status, "pending_approval")

      result = approval_for(receipt, actor: approver).approve!

      expect(result.ok?).to be(true)
      receipt.reload
      expect(receipt).to be_approval_approved
      expect(receipt.decided_by).to eq(approver)
      expect(receipt.decided_at).to be_present
    end

    it "never posts stock, custody, or a settlement — approval is purely a purchasing decision" do
      receipt = draft_receipt
      receipt.update_column(:approval_status, "pending_approval")

      approval_for(receipt, actor: approver).approve!

      expect(receipt.reload.status).to eq("draft") # inventory status untouched
      expect(receipt.financial_settlements.count).to eq(0)
      expect(receipt.custody_transactions.count).to eq(0)
    end

    it "blocks self-approval by the requester, with the owner exception" do
      receipt = draft_receipt(created_by: requester)
      receipt.update_column(:approval_status, "pending_approval")

      self_result = approval_for(receipt, actor: requester).approve!
      expect(self_result.ok?).to be(false)
      expect(self_result.error).to eq(Approvals::SelfApproval.error_message)
      expect(receipt.reload).to be_approval_pending_approval

      owner_receipt = draft_receipt(created_by: owner)
      owner_receipt.update_column(:approval_status, "pending_approval")
      owner_result = approval_for(owner_receipt, actor: owner).approve!
      expect(owner_result.ok?).to be(true)
    end

    it "refuses to approve a draft (never submitted) receipt" do
      receipt = draft_receipt
      result = approval_for(receipt, actor: approver).approve!
      expect(result.ok?).to be(false)
    end
  end

  describe "#reject!" do
    it "moves pending_approval to rejected, stores the reason, and logs it" do
      receipt = draft_receipt
      receipt.update_column(:approval_status, "pending_approval")

      result = approval_for(receipt, actor: approver).reject!(reason: "budget exceeded")

      expect(result.ok?).to be(true)
      receipt.reload
      expect(receipt).to be_approval_rejected
      expect(receipt.decided_by).to eq(approver)
      expect(receipt.rejection_reason).to eq("budget exceeded")
      log = AuditLog.for_auditable(receipt).find_by(action: "reject")
      expect(log.metadata["reason"]).to eq("budget exceeded")
    end

    it "requires a non-blank reason" do
      receipt = draft_receipt
      receipt.update_column(:approval_status, "pending_approval")

      result = approval_for(receipt, actor: approver).reject!(reason: "  ")
      expect(result.ok?).to be(false)
      expect(receipt.reload).to be_approval_pending_approval
    end

    it "blocks self-rejection by the requester" do
      receipt = draft_receipt(created_by: requester)
      receipt.update_column(:approval_status, "pending_approval")

      result = approval_for(receipt, actor: requester).reject!(reason: "changed my mind")
      expect(result.ok?).to be(false)
      expect(receipt.reload).to be_approval_pending_approval
    end
  end
end
