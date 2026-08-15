module Finance
  # Records an independent refund/return against a DailyReconciliation.
  #
  # Deliberately NOT a TillHandover: a refund is not a custody transfer or a
  # day close, so it must never touch TillSession.current_holder, never
  # require a recipient, and never force the till to close. Each call creates
  # a new, independent TillRefund row — nothing is ever merged or replaced,
  # mirroring TillDepositRecorder's append-only shape.
  #
  # Refunds are folded into session_amounts exactly once, at day close, by
  # Finance::TillHandoverCreator.sync_session_amounts! — so this service never
  # touches session_amounts itself, and a refund recorded before or after the
  # handover chain is always counted exactly once.
  #
  # Race-safe and idempotent: the DR row lock plus an optional client-supplied
  # idempotency_key make a retried submission (double form-submit, refreshed
  # request) return the original record instead of creating a duplicate,
  # mirroring TillDepositRecorder.
  #
  # Also called from Finance::SalesImports::Importer to auto-create a
  # TillRefund for an imported POS refund row (see there for the actor/
  # idempotency-key strategy) — the exact same rules apply: no-op if the DR
  # isn't open (protects a closed/finalized period), no-op on a repeated
  # idempotency_key (protects against duplicate creation on re-import).
  class TillRefundCreator
    include AuditLoggable

    Result = Struct.new(:ok, :refund, :error, keyword_init: true) { def ok? = ok }

    def initialize(daily_reconciliation_id, actor:, params:)
      @daily_reconciliation_id = daily_reconciliation_id
      @actor                   = actor
      @params                  = params
    end

    def call
      @daily_reconciliation = DailyReconciliation
                                .where(business_id: @actor.business_id)
                                .includes(:business, :branch)
                                .find(@daily_reconciliation_id)

      unless @daily_reconciliation.open?
        return Result.new(ok: false, error: I18n.t("till_refunds.errors.session_not_open"))
      end

      unless PaymentMethod.for_business(@daily_reconciliation.business).active.exists?(@params[:payment_method_id])
        return Result.new(ok: false, error: I18n.t("till_refunds.errors.invalid_payment_method"))
      end

      amount = @params[:amount].to_s.to_d
      if amount <= 0
        return Result.new(ok: false, error: I18n.t("till_refunds.errors.amount_required"))
      end

      idempotency_key = @params[:idempotency_key].presence

      result = nil
      @daily_reconciliation.with_lock do
        if idempotency_key && (existing = @daily_reconciliation.till_refunds.find_by(idempotency_key: idempotency_key))
          result = Result.new(ok: true, refund: existing)
          next
        end

        refund = @daily_reconciliation.till_refunds.create!(
          payment_method_id: @params[:payment_method_id],
          processed_by:      @actor,
          amount:            amount,
          refunded_at:       @params[:refunded_at].presence || Time.current,
          notes:             @params[:notes],
          idempotency_key:   idempotency_key
        )

        log_audit(actor: @actor, auditable: refund, action: "create",
                  metadata: { amount: refund.amount.to_s,
                               daily_reconciliation_id: @daily_reconciliation.id,
                               payment_method_id:       refund.payment_method_id })

        result = Result.new(ok: true, refund: refund)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
