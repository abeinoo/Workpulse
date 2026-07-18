module Inventory
  # Handles the goods receipt approval lifecycle: draft/rejected → pending_approval
  # → approved | rejected. Modeled directly on Finance::ExpenseApproval.
  #
  # This is purely a purchasing decision — "I approve this purchase." It NEVER
  # posts inventory movements, custody transactions, or financial settlements;
  # that only happens at confirmation (Inventory::GoodsReceiptConfirmationService),
  # a completely separate step gated on approval_status == "approved".
  #
  # Self-approval is blocked (the requester who created/submitted the receipt
  # may not approve or reject their own request), with the business-owner
  # exception, via the shared Approvals::SelfApproval rule.
  class GoodsReceiptApproval
    include AuditLoggable

    Result = Struct.new(:ok, :receipt, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(goods_receipt_id:, actor:)
      @goods_receipt_id = goods_receipt_id
      @actor            = actor
    end

    # draft/rejected → pending_approval
    def submit!
      transition(from: %w[draft rejected], to: "pending_approval", action: "submit_for_approval") do
        receipt.rejection_reason = nil
      end
    end

    # pending_approval → approved
    def approve!
      return self_approval_error if self_approval?

      transition(from: "pending_approval", to: "approved", action: "approve") do
        receipt.decided_by = @actor
        receipt.decided_at = Time.current
      end
    end

    # pending_approval → rejected
    def reject!(reason:)
      return self_approval_error if self_approval?

      reason = reason.to_s.strip
      if reason.blank?
        receipt.errors.add(:rejection_reason, :blank)
        return Result.new(ok: false, receipt: receipt, error: receipt.errors.full_messages.to_sentence)
      end

      transition(from: "pending_approval", to: "rejected", action: "reject", metadata: { reason: reason }) do
        receipt.decided_by       = @actor
        receipt.decided_at       = Time.current
        receipt.rejection_reason = reason
      end
    end

    private

    def receipt
      @receipt ||= GoodsReceipt.where(business_id: @actor.business_id).find(@goods_receipt_id)
    end

    def self_approval?
      return false if @actor.owner?

      Approvals::SelfApproval.by_requester?(approver: @actor, requester: receipt.created_by_id)
    end

    def self_approval_error
      Result.new(ok: false, receipt: receipt, error: Approvals::SelfApproval.error_message)
    end

    def transition(from:, to:, action:, metadata: {})
      allowed_from = Array(from)
      unless allowed_from.include?(receipt.approval_status)
        return Result.new(ok: false, receipt: receipt,
                          error: I18n.t("inventory.goods_receipts.errors.invalid_approval_transition"))
      end

      from_status = receipt.approval_status
      ActiveRecord::Base.transaction do
        receipt.approval_status = to
        yield if block_given?
        receipt.save!
        log_audit(actor: @actor, auditable: receipt, action: action,
                  changes: { approval_status: [ from_status, to ] }, metadata: metadata)
      end
      Result.new(ok: true, receipt: receipt)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, receipt: receipt, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
