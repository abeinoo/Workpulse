module Inventory
  # Handles the goods receipt approval lifecycle: draft/rejected → pending_approval
  # → approved | rejected. Modeled directly on Finance::ExpenseApproval.
  #
  # Approval — not confirmation/receiving — is the financial event. The
  # funding source decides what it records, all inside the same transaction as
  # the approval_status transition:
  #   - employee_custody: validates and deducts the approver-time balance,
  #     records a FinancialSettlement for the full amount, and posts a linked
  #     CustodyTransaction.
  #   - company_cash / bank_account: paid on the spot, so a full-amount
  #     FinancialSettlement is recorded with that source_kind and no funding
  #     account (no CashAccount/BankAccount model exists — no balance moves).
  #   - supplier_credit: nothing — the receipt stays pending_settlement and is
  #     paid off later through Inventory::GoodsReceiptSettlementRecorder. It NEVER
  # posts inventory movements — that stays entirely with warehouse receiving
  # (Inventory::GoodsReceiptConfirmationService), which is purely an inventory
  # event and moves no money, gated on approval_status == "approved".
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

    # pending_approval → approved. The financial event: validates and deducts
    # the funding source's balance, then records the settlement + custody
    # transaction, all inside the transition's transaction.
    def approve!
      return self_approval_error if self_approval?

      # Row lock (reloads the receipt): a concurrent second approval waits,
      # then sees "approved" and is refused — the payment is recorded once.
      receipt.with_lock do
        return invalid_transition_error unless receipt.approval_status == "pending_approval"

        account = nil
        if receipt.employee_custody_funded?
          account = receipt.funding_source
          account.with_lock do
            return insufficient_balance_error if account.computed_balance < receipt.total_value
          end
        end

        transition(from: "pending_approval", to: "approved", action: "approve") do
          receipt.decided_by = @actor
          receipt.decided_at = Time.current
          post_custody_deduction(account) if account
          post_accountless_payment if receipt.accountless_payment_funded?
        end
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

    def already_processed_error
      Result.new(ok: false, receipt: receipt,
                error: I18n.t("inventory.goods_receipts.errors.already_processed"))
    end

    def invalid_transition_error
      Result.new(ok: false, receipt: receipt,
                error: I18n.t("inventory.goods_receipts.errors.invalid_approval_transition"))
    end

    def insufficient_balance_error
      Result.new(ok: false, receipt: receipt,
                error: I18n.t("inventory.goods_receipts.errors.insufficient_custody_balance"))
    end

    # Creates the FinancialSettlement + linked CustodyTransaction and deducts
    # the account balance. Called from inside the approval transaction — the
    # financial event happens exactly once, at approval, never at confirmation.
    def post_custody_deduction(account)
      settlement_result = FinancialSettlementService.create(
        settleable:     receipt,
        funding_source: account,
        amount:         receipt.total_value,
        actor:          @actor,
        notes:          I18n.t("finance.custody.inventory_purchase_note", reference: receipt.receipt_number)
      )
      raise ActiveRecord::RecordInvalid, settlement_result.settlement unless settlement_result.ok?

      account.custody_transactions.create!(
        business:             account.business,
        txn_type:             "inventory_purchase",
        amount:               -receipt.total_value,
        source:               receipt,
        financial_settlement: settlement_result.settlement,
        created_by:           @actor,
        notes:                I18n.t("finance.custody.inventory_purchase_note", reference: receipt.receipt_number)
      )
      account.refresh_balance!
    end

    # Company cash / bank: the full amount is paid at approval. Same ledger
    # (FinancialSettlementService) and the same reversal path on void as every
    # other settlement; source_kind records where the money came from.
    def post_accountless_payment
      return unless receipt.total_value.positive?

      result = FinancialSettlementService.create(
        settleable:  receipt,
        source_kind: receipt.funding_source_kind,
        reference:   receipt.receipt_number,
        amount:      receipt.total_value,
        actor:       @actor,
        notes:       I18n.t("finance.custody.inventory_purchase_note", reference: receipt.receipt_number)
      )
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?
    end

    def transition(from:, to:, action:, metadata: {})
      return already_processed_error if receipt.voided?

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
