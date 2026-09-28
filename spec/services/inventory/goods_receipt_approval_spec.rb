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

  describe "#approve! payment by funding source" do
    def pending_receipt(kind, unit_cost: 100)
      r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, created_by: requester,
                                        funding_source_kind: kind)
      r.items.build(product: product, quantity: 2, unit_cost: unit_cost)
      r.save!
      r.update_column(:approval_status, "pending_approval")
      r
    end

    %w[company_cash bank_account].each do |kind|
      it "records one full, accountless #{kind} settlement inside the approval" do
        receipt = pending_receipt(kind)
        expect(approval_for(receipt, actor: approver).approve!).to be_ok

        expect(receipt.reload).to be_settled
        expect(receipt.financial_settlements.sole)
          .to have_attributes(amount: 200, source_kind: kind, funding_source_id: nil, created_by_id: approver.id)
      end
    end

    it "records nothing for supplier_credit" do
      receipt = pending_receipt("supplier_credit")
      expect(approval_for(receipt, actor: approver).approve!).to be_ok
      expect(receipt.reload.financial_settlements).to be_empty
      expect(receipt).to be_pending_settlement
    end

    it "approves a zero-value cash receipt without a (zero-amount) settlement" do
      receipt = pending_receipt("company_cash", unit_cost: 0)
      expect(approval_for(receipt, actor: approver).approve!).to be_ok
      expect(receipt.reload.financial_settlements).to be_empty
    end
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

    it "never posts stock for a supplier-credit receipt — approval is a financial decision, not an inventory event" do
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

    context "with an employee-custody-funded receipt" do
      let(:account) { create(:custody_account, business: business) }

      def top_up!(amount)
        account.custody_transactions.create!(business: business, txn_type: "top_up", amount: amount)
        account.refresh_balance!
      end

      def custody_receipt(qty: 1, cost: 100)
        r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, created_by: requester,
                                          funding_source_kind: "employee_custody", funding_source: account)
        r.items.build(product: product, quantity: qty, unit_cost: cost)
        r.save!
        r.update_column(:approval_status, "pending_approval")
        r
      end

      it "is the financial event: deducts the balance and records a settlement plus a linked custody transaction, without posting stock" do
        top_up!(1000)
        receipt = custody_receipt(qty: 10, cost: 50)

        result = approval_for(receipt, actor: approver).approve!

        expect(result.ok?).to be(true)
        receipt.reload
        expect(receipt).to be_approval_approved
        expect(receipt.status).to eq("draft") # not confirmed — inventory posting is a separate step
        expect(account.reload.current_balance).to eq(500)

        settlement = receipt.financial_settlements.sole
        expect(settlement.amount).to eq(500)
        expect(settlement.funding_source).to eq(account)
        expect(receipt).to be_settled

        txn = receipt.custody_transactions.of_type("inventory_purchase").first
        expect(txn).to be_present
        expect(txn.amount).to eq(-500)
        expect(txn.custody_account).to eq(account)
      end

      it "blocks approval when the balance is insufficient, leaving the receipt pending and creating no settlement or transaction" do
        top_up!(100)
        receipt = custody_receipt(qty: 10, cost: 50)

        result = approval_for(receipt, actor: approver).approve!

        expect(result.ok?).to be(false)
        expect(result.error).to eq(I18n.t("inventory.goods_receipts.errors.insufficient_custody_balance"))
        expect(receipt.reload).to be_approval_pending_approval
        expect(account.reload.current_balance).to eq(100)
        expect(receipt.custody_transactions.count).to eq(0)
        expect(receipt.financial_settlements.count).to eq(0)
        expect(receipt).to be_pending_settlement
      end
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

  describe "a voided receipt (terminal state)" do
    def voided_receipt(approval_status: "approved")
      r = draft_receipt
      r.update_columns(approval_status: approval_status, voided_at: Time.current, void_reason: "test")
      r
    end

    it "refuses submit!, approve!, and reject! — a voided receipt can never re-enter the workflow" do
      submit_result = approval_for(voided_receipt(approval_status: "draft"), actor: approver).submit!
      expect(submit_result.ok?).to be(false)
      expect(submit_result.error).to eq(I18n.t("inventory.goods_receipts.errors.already_processed"))

      approve_result = approval_for(voided_receipt(approval_status: "pending_approval"), actor: approver).approve!
      expect(approve_result.ok?).to be(false)
      expect(approve_result.error).to eq(I18n.t("inventory.goods_receipts.errors.already_processed"))

      reject_result = approval_for(voided_receipt(approval_status: "pending_approval"), actor: approver).reject!(reason: "x")
      expect(reject_result.ok?).to be(false)
      expect(reject_result.error).to eq(I18n.t("inventory.goods_receipts.errors.already_processed"))
    end
  end
end
