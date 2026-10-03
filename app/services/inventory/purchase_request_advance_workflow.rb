module Inventory
  # Lifecycle of one PurchaseRequestAdvance (see that model):
  #
  #   confirm!  pending → confirmed   THE financial event: posts one
  #             FinancialSettlement on the Purchase Request and, for employee
  #             custody, its linked "inventory_purchase" CustodyTransaction
  #             debit — exactly how Goods Receipt payments are recorded. No
  #             balance check: the custody balance may go negative.
  #   cancel!   pending → cancelled   nothing financial ever happened.
  #   reverse!  confirmed → reversed  equal-and-opposite settlement
  #             (FinancialSettlementService.reverse) + custody credit
  #             ("inventory_purchase_reversal"); the originals are never touched.
  #
  # Every step runs in one transaction with the Purchase Request row locked
  # first (the same lock receipt approval takes before applying advances), then
  # the advance row (reloaded) — so a double click / retry finds the advance no
  # longer pending and is refused: custody is never debited twice.
  #
  # Confirmation is blocked for the person who recorded the advance (shared
  # Approvals::SelfApproval rule, owner exempt), like every other approval.
  # Reversal is refused once any part of the advance has been applied to a
  # receipt — void that receipt first (which returns the applied amount to the
  # advance), so an advance can never be both refunded and consumed.
  class PurchaseRequestAdvanceWorkflow
    include AuditLoggable

    Result = Struct.new(:ok, :advance, :error, keyword_init: true) { def ok? = ok }

    def initialize(advance_id:, actor:)
      @advance_id = advance_id
      @actor      = actor
    end

    def confirm!
      return Result.new(ok: false, advance: advance, error: Approvals::SelfApproval.error_message) if self_approval?

      in_locked_transaction do
        return err(:invalid_transition) unless advance.pending?
        return err(:not_allowed_for_status) unless purchase_request.receivable?

        capacity = purchase_request.advance_capacity
        return err(:exceeds_remaining, remaining: format_amount(capacity)) if advance.amount > capacity

        account = advance.custody_account
        if account
          # Serializes writes to the account's cached balance; never a limit.
          account.lock!
          return err(:custody_account_inactive) unless account.active?
        end

        settlement = post_settlement!
        debit_custody!(account, settlement) if account

        advance.update!(status: "confirmed", confirmed_by: @actor, confirmed_at: Time.current,
                        financial_settlement: settlement)
        log_audit(actor: @actor, auditable: advance, action: "confirm",
                  changes: { status: %w[pending confirmed] },
                  metadata: audit_metadata(settlement_id: settlement.id))
      end
    end

    def cancel!(reason:)
      reason = reason.to_s.strip
      return err(:reason_required) if reason.blank?

      in_locked_transaction do
        return err(:invalid_transition) unless advance.pending?

        advance.update!(status: "cancelled", cancelled_by: @actor, cancelled_at: Time.current,
                        cancellation_reason: reason)
        log_audit(actor: @actor, auditable: advance, action: "cancel",
                  changes: { status: %w[pending cancelled] }, metadata: audit_metadata(reason: reason))
      end
    end

    def reverse!(reason:)
      reason = reason.to_s.strip
      return err(:reason_required) if reason.blank?

      in_locked_transaction do
        return err(:invalid_transition) unless advance.confirmed?
        return err(:already_applied) if advance.applied_amount.positive?

        original = advance.financial_settlement
        result   = FinancialSettlementService.reverse(settlement: original, actor: @actor, notes: reason)
        raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

        reversal = result.settlement
        credit_custody!(original, reversal, reason) if original.funding_source.is_a?(CustodyAccount)

        advance.update!(status: "reversed", reversed_by: @actor, reversed_at: Time.current, reversal_reason: reason)
        log_audit(actor: @actor, auditable: advance, action: "reverse",
                  changes: { status: %w[confirmed reversed] },
                  metadata: audit_metadata(settlement_id: original.id, reversal_id: reversal.id, reason: reason))
      end
    end

    private

    def advance
      @advance ||= PurchaseRequestAdvance.where(business_id: @actor.business_id).find(@advance_id)
    end

    def purchase_request = advance.purchase_request

    def self_approval?
      return false if @actor.owner?

      Approvals::SelfApproval.by_requester?(approver: @actor, requester: advance.created_by_id)
    end

    # Lock order matches receipt approval: Purchase Request, then the advance
    # (reloaded by lock!), then — inside the block — the custody account.
    def in_locked_transaction
      ActiveRecord::Base.transaction do
        purchase_request.lock!
        advance.lock!
        yield
      end
      Result.new(ok: true, advance: advance)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, advance: advance, error: e.record.errors.full_messages.to_sentence)
    end

    def post_settlement!
      result = FinancialSettlementService.create(
        settleable:     purchase_request,
        funding_source: advance.custody_account,
        source_kind:    advance.source_kind,
        reference:      advance.reference.presence || purchase_request.request_number,
        amount:         advance.amount,
        actor:          @actor,
        notes:          I18n.t("inventory.purchase_request_advances.settlement_note",
                               reference: purchase_request.request_number, advance: advance.id),
        settled_at:     advance.paid_on
      )
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

      result.settlement
    end

    def debit_custody!(account, settlement)
      account.custody_transactions.create!(
        business:             account.business,
        txn_type:             "inventory_purchase",
        amount:               -advance.amount,
        source:               purchase_request,
        financial_settlement: settlement,
        created_by:           @actor,
        notes:                I18n.t("finance.custody.purchase_request_advance_note",
                                     reference: purchase_request.request_number, advance: advance.id,
                                     supplier: purchase_request.supplier.name)
      )
      account.refresh_balance!
    end

    def credit_custody!(original, reversal, reason)
      account = original.funding_source
      account.lock!
      account.custody_transactions.create!(
        business:             account.business,
        txn_type:             "inventory_purchase_reversal",
        amount:               original.amount,
        source:               purchase_request,
        financial_settlement: reversal,
        created_by:           @actor,
        notes:                I18n.t("finance.custody.purchase_request_advance_reversal_note",
                                     reference: purchase_request.request_number, advance: advance.id, reason: reason)
      )
      account.refresh_balance!
    end

    def audit_metadata(**extra)
      { purchase_request_id: purchase_request.id, request_number: purchase_request.request_number,
        supplier_id: purchase_request.supplier_id, amount: advance.amount.to_s, source_kind: advance.source_kind,
        custody_account_id: advance.custody_account_id, employee_id: advance.custody_account&.user_id,
        paid_on: advance.paid_on.to_s, reference: advance.reference }.merge(extra)
    end

    def format_amount(value)
      ActiveSupport::NumberHelper.number_to_rounded(value, precision: 2, delimiter: ",")
    end

    def err(key, **)
      Result.new(ok: false, advance: advance, error: I18n.t("inventory.purchase_request_advances.errors.#{key}", **))
    end
  end
end
