module Inventory
  # After-the-fact lifecycle of one PurchaseRequestAdvance (see that model).
  # Recording an advance posts its funding at once
  # (Inventory::PurchaseRequestAdvanceRecorder) — there is no confirmation step.
  #
  #   reverse!  confirmed → reversed  the opposite custody rows (funding), or the
  #             equal-and-opposite settlement + custody credit (LEGACY supplier
  #             payment); the originals are never touched.
  #   cancel!   pending → cancelled   only for advances still PENDING from the
  #             old two-step workflow (funding or legacy): nothing financial
  #             ever happened to them, and they are never executed or replayed —
  #             cancel with a reason, then record a new advance.
  #
  # Every step runs in one transaction with the Purchase Request row locked
  # first (the same lock receipt approval and the recorder take), then the
  # advance row (reloaded) — so a double click / retry finds the advance no
  # longer in the expected status and is refused: custody is never moved twice.
  # The ledger writes are Finance & Sales': they go only through
  # Inventory::PurchaseRequestAdvanceEffects, inside this transaction, after
  # these locks. Reversal of a legacy advance is refused once any part of it has
  # been applied to a receipt — void that receipt first.
  class PurchaseRequestAdvanceWorkflow
    include AuditLoggable

    Result = Struct.new(:ok, :advance, :error, keyword_init: true) { def ok? = ok }

    def initialize(advance_id:, actor:)
      @advance_id = advance_id
      @actor      = actor
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

        advance.funding? ? reverse_funding!(reason) : reverse_settlement!(reason)
      end
    end

    private

    def source_employee_id = advance.custody_account&.user_id

    def reverse_settlement!(reason)
      reversal = Inventory::PurchaseRequestAdvanceEffects.advance_reversed(advance: advance, actor: @actor, reason: reason)

      advance.update!(status: "reversed", reversed_by: @actor, reversed_at: Time.current, reversal_reason: reason)
      log_audit(actor: @actor, auditable: advance, action: "reverse",
                changes: { status: %w[confirmed reversed] },
                metadata: audit_metadata(settlement_id: reversal.settlement_id, reversal_id: reversal.reversal_id,
                                         reason: reason))
    end

    def reverse_funding!(reason)
      reversal = Inventory::PurchaseRequestAdvanceEffects.advance_funding_reversed(advance: advance, actor: @actor,
                                                                                  reason: reason)

      advance.update!(status: "reversed", reversed_by: @actor, reversed_at: Time.current, reversal_reason: reason,
                      funding_reversal_transaction_id: reversal.transaction_id)
      log_audit(actor: @actor, auditable: advance, action: "reverse",
                changes: { status: %w[confirmed reversed] },
                metadata: audit_metadata(funding_transaction_id: advance.funding_transaction_id,
                                         funding_reversal_transaction_id: reversal.transaction_id,
                                         funding_reversal_counterparty_id: reversal.counterparty_id,
                                         reason: reason))
    end

    # Service-level reach (Phase 2): the advance's purchase request must be in
    # the actor's warehouse scope (PurchaseRequestPolicy::Scope, the rule
    # PurchaseRequestApproval uses) — otherwise it is not found.
    def advance
      @advance ||= PurchaseRequestAdvance.where(business_id: @actor.business_id)
                                         .where(purchase_request_id: PurchaseRequestPolicy::Scope.new(@actor, PurchaseRequest).resolve.select(:id))
                                         .find(@advance_id)
    end

    def purchase_request = advance.purchase_request

    # Lock order matches receipt approval: Purchase Request, then the advance
    # (reloaded by lock!), then — inside the block, in the Finance & Sales
    # handler — the custody account.
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

    def audit_metadata(**extra)
      { purchase_request_id: purchase_request.id, request_number: purchase_request.request_number,
        supplier_id: purchase_request.supplier_id, amount: advance.amount.to_s, source_kind: advance.source_kind,
        custody_account_id: advance.custody_account_id, employee_id: source_employee_id,
        responsible_employee_id: purchase_request.responsible_employee_id,
        recipient_custody_account_id: advance.recipient_custody_account_id,
        paid_on: advance.paid_on.to_s, reference: advance.reference }.merge(extra)
    end

    def err(key, **)
      Result.new(ok: false, advance: advance, error: I18n.t("inventory.purchase_request_advances.errors.#{key}", **))
    end
  end
end
