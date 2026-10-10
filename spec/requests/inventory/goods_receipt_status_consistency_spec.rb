require "rails_helper"

# Approval status and receiving status must never contradict each other.
# Bug: cancelling a receipt awaiting approval voided it (receiving "ملغى") but
# left approval_status pending_approval ("بانتظار الاعتماد") — it still showed
# as awaiting approval and was counted in the pending-approval KPI.
#
# Sources of truth: approval_status (stored enum; "cancelled" is set by
# Inventory::GoodsReceiptVoider for undecided approvals) and the derived
# GoodsReceipt#receiving_status (voided_at / status / approval_status).
# Receiving is all-or-nothing for goods receipts: there is no partial state.
RSpec.describe "Goods receipt approval/receiving status consistency", type: :request do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:admin) { create(:user, :super_admin, business: business, preferred_locale: "ar") }

  def build_receipt(approval_status: "pending_approval")
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r.update_column(:approval_status, approval_status)
    r.reload
  end

  def approval(receipt) = Inventory::GoodsReceiptApproval.new(goods_receipt_id: receipt.id, actor: admin)
  def approved_receipt = build_receipt.tap { |r| expect(approval(r).approve!).to be_ok }.reload

  def received_receipt
    approved_receipt.tap do |r|
      expect(Inventory::GoodsReceiptConfirmationService.new(goods_receipt_id: r.id, actor: admin).call).to be_ok
    end.reload
  end

  def cancel(receipt, reason: "مكرر")
    Inventory::GoodsReceiptVoider.new(goods_receipt_id: receipt.id, actor: admin, reason: reason).call
  end

  def ar(key) = I18n.t("inventory.goods_receipts.#{key}", locale: :ar)

  # [approval label, receiving label] from the index row of `receipt`.
  def index_badges(receipt, **filters)
    sign_in admin
    get inventory_goods_receipts_path(filters)
    row = Nokogiri::HTML(response.body).css("tbody tr").find { |tr| tr.text.include?(receipt.receipt_number) }
    row&.css(".badge")&.map { |b| b.text.strip }
  end

  def show_badges(receipt)
    sign_in admin
    get inventory_goods_receipt_path(receipt)
    Nokogiri::HTML(response.body).css(".badge--md").first(2).map { |b| b.text.strip }
  end

  describe "pending approval" do
    it "shows بانتظار الاعتماد with a not-received (never cancelled) receiving status" do
      receipt = build_receipt
      expect(receipt.receiving_status).to eq("not_received")
      expect(index_badges(receipt)).to eq([ ar("approval_statuses.pending_approval"), ar("receipt_statuses.not_received") ])
    end
  end

  describe "pending approval → cancel" do
    it "leaves the approval workflow: approval cancelled, receiving voided, audited" do
      receipt = build_receipt
      expect(cancel(receipt)).to be_ok

      receipt.reload
      expect(receipt).to have_attributes(approval_status: "cancelled", receiving_status: "voided")
      expect(AuditLog.find_by(auditable: receipt, action: "void").metadata)
        .to include("approval_status" => [ "pending_approval", "cancelled" ])
      expect(index_badges(receipt)).to eq([ ar("approval_statuses.cancelled"), ar("receipt_statuses.voided") ])
      expect(show_badges(receipt)).to eq([ ar("approval_statuses.cancelled"), ar("receipt_statuses.voided") ])
    end

    it "through the cancel action as well" do
      receipt = build_receipt
      sign_in admin
      patch cancel_inventory_goods_receipt_path(receipt), params: { cancellation_reason: "مكرر" }
      expect(receipt.reload).to have_attributes(approval_status: "cancelled", receiving_status: "voided")
    end

    it "a cancelled draft is cancelled too, not left as مسودة" do
      receipt = build_receipt(approval_status: "draft")
      cancel(receipt)
      expect(receipt.reload.approval_status).to eq("cancelled")
    end

    it "is no longer listed or counted as awaiting approval" do
      cancelled = build_receipt.tap { |r| cancel(r) }
      pending   = build_receipt

      sign_in admin
      get inventory_goods_receipts_path(approval_status: "pending_approval")
      expect(response.body).to include(pending.receipt_number)
      expect(response.body).not_to include(cancelled.receipt_number)
      expect(GoodsReceipt.for_approval_status("pending_approval")).to contain_exactly(pending)
    end
  end

  describe "cancelled receipt cannot re-enter the approval workflow" do
    let(:receipt) { build_receipt.tap { |r| cancel(r) }.reload }

    it "cannot be approved or rejected (service)" do
      expect(approval(receipt).approve!).not_to be_ok
      expect(approval(receipt).reject!(reason: "x")).not_to be_ok
      expect(approval(receipt).submit!).not_to be_ok
      expect(receipt.reload).to have_attributes(approval_status: "cancelled", decided_by_id: nil)
      expect(receipt.financial_settlements).to be_empty
    end

    it "cannot be approved or rejected (policy + endpoint)" do
      policy = GoodsReceiptPolicy.new(admin, receipt)
      expect([ policy.approve?, policy.reject?, policy.cancel?, policy.void?, policy.confirm? ]).to all(be false)

      sign_in admin
      post approve_inventory_goods_receipt_path(receipt)
      post reject_inventory_goods_receipt_path(receipt), params: { rejection_reason: "x" }
      expect(receipt.reload.approval_status).to eq("cancelled")
    end

    it "cannot be cancelled again" do
      expect(cancel(receipt)).not_to be_ok
      expect(receipt.reload.approval_status).to eq("cancelled")
    end
  end

  describe "rejected" do
    it "shows مرفوض with a cannot-be-received receiving status" do
      receipt = build_receipt
      expect(approval(receipt).reject!(reason: "سعر خاطئ")).to be_ok
      receipt.reload

      expect(receipt).to have_attributes(approval_status: "rejected", receiving_status: "not_receivable")
      expect(index_badges(receipt)).to eq([ ar("approval_statuses.rejected"), ar("receipt_statuses.not_receivable") ])
      expect(GoodsReceiptPolicy.new(admin, receipt).confirm?).to be false
    end

    it "is filtered under not_receivable, not not_received" do
      rejected = build_receipt.tap { |r| approval(r).reject!(reason: "x") }
      pending  = build_receipt

      expect(GoodsReceipt.for_receiving_status("not_receivable")).to contain_exactly(rejected)
      expect(GoodsReceipt.for_receiving_status("not_received")).to contain_exactly(pending)
    end
  end

  describe "approved (unchanged behaviour)" do
    it "approved + not received" do
      receipt = approved_receipt
      expect(receipt.receiving_status).to eq("not_received")
      expect(index_badges(receipt)).to eq([ ar("approval_statuses.approved"), ar("receipt_statuses.not_received") ])
    end

    it "approved + received" do
      receipt = received_receipt
      expect(receipt.receiving_status).to eq("received")
      expect(index_badges(receipt)).to eq([ ar("approval_statuses.approved"), ar("receipt_statuses.received") ])
    end

    it "approved, then voided: the approval decision is kept as history" do
      receipt = approved_receipt
      expect(cancel(receipt, reason: "خطأ")).to be_ok
      expect(receipt.reload).to have_attributes(approval_status: "approved", receiving_status: "voided")
      expect(AuditLog.find_by(auditable: receipt, action: "void").metadata).not_to have_key("approval_status")
    end

    it "received, then voided: approval kept, stock reversed" do
      receipt = received_receipt
      expect(cancel(receipt, reason: "خطأ")).to be_ok
      expect(receipt.reload).to have_attributes(approval_status: "approved", receiving_status: "voided")
    end
  end

  describe "historical normalization (Inventory::GoodsReceiptCancelledApprovalNormalizer)" do
    # The pre-fix state: voided while still pending / draft.
    def legacy_cancelled(approval_status)
      build_receipt(approval_status: approval_status).tap do |r|
        r.update_columns(voided_at: 1.day.ago, voided_by_id: admin.id, void_reason: "مكرر")
      end
    end

    let!(:legacy_pending) { legacy_cancelled("pending_approval") }
    let!(:legacy_draft)   { legacy_cancelled("draft") }
    let!(:valid_pending)  { build_receipt }
    let!(:valid_approved) { approved_receipt }
    let!(:valid_rejected) { build_receipt.tap { |r| approval(r).reject!(reason: "x") } }
    let!(:approved_voided) { approved_receipt.tap { |r| cancel(r, reason: "خطأ") } }

    it "dry run lists only the invalid records and writes nothing" do
      result = Inventory::GoodsReceiptCancelledApprovalNormalizer.new.call

      expect(result.candidates).to contain_exactly(legacy_pending, legacy_draft)
      expect(result.updated).to be_empty
      expect(legacy_pending.reload.approval_status).to eq("pending_approval")
    end

    it "apply moves them to cancelled, audits each, and leaves valid records unchanged" do
      untouched = [ valid_pending, valid_approved, valid_rejected, approved_voided ].map(&:reload)
      before    = untouched.map { |r| r.attributes.except("updated_at") }

      result = Inventory::GoodsReceiptCancelledApprovalNormalizer.new(apply: true).call

      expect(result.updated).to contain_exactly(legacy_pending, legacy_draft)
      expect(legacy_pending.reload).to have_attributes(approval_status: "cancelled", receiving_status: "voided")
      expect(legacy_draft.reload.approval_status).to eq("cancelled")
      expect(AuditLog.find_by(auditable: legacy_pending, action: "normalize_cancelled_approval").changes_json)
        .to eq("approval_status" => [ "pending_approval", "cancelled" ])
      expect(untouched.map { |r| r.reload.attributes.except("updated_at") }).to eq(before)

      expect(Inventory::GoodsReceiptCancelledApprovalNormalizer.candidates).to be_empty
    end
  end
end
