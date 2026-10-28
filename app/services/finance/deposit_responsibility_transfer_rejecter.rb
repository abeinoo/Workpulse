module Finance
  # The recipient declines a pending DepositResponsibilityTransfer.
  #
  # On rejection:
  #   - transfer is stamped with rejected_at / rejected_by / rejection_reason
  #   - TillSession.depositor_id is NOT touched — from_user stays responsible
  #   - The one-pending-per-DR index is released, so a new transfer may be
  #     requested
  #
  # Only the named recipient may reject — unlike accept there is no owner
  # override (declining on someone's behalf has no business meaning). Runs
  # under the same DR row lock as the acceptor, so accept vs reject (or two
  # tabs) can never both succeed.
  class DepositResponsibilityTransferRejecter
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    def initialize(transfer_id, actor:, reason:)
      @transfer_id = transfer_id
      @actor       = actor
      @reason      = reason.to_s.strip.presence
    end

    def call
      @transfer = DepositResponsibilityTransfer
                    .joins(:daily_reconciliation)
                    .where(daily_reconciliations: { business_id: @actor.business_id })
                    .find(@transfer_id)

      return failure(:wrong_recipient) unless @transfer.to_user_id == @actor.id
      return failure(:rejection_reason_blank) unless @reason
      if @reason.length > DepositResponsibilityTransfer::REJECTION_REASON_MAX_LENGTH
        return failure(:rejection_reason_too_long, count: DepositResponsibilityTransfer::REJECTION_REASON_MAX_LENGTH)
      end

      ActiveRecord::Base.transaction do
        @transfer.daily_reconciliation.lock!
        @transfer.reload
        raise ArgumentError, error_text(:not_pending) unless @transfer.pending?

        @transfer.update!(rejected_at: Time.current, rejected_by: @actor, rejection_reason: @reason)

        log_audit!(actor: @actor, auditable: @transfer, action: "reject",
                   metadata: { daily_reconciliation_id: @transfer.daily_reconciliation_id,
                               reason:                  @reason })
      end

      Result.new(ok: true)
    rescue ArgumentError => e
      Result.new(ok: false, error: e.message)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      Result.new(ok: false, error: I18n.t("finance.daily_reconciliations.errors.deposit_transfer_audit_failed"))
    end

    private

    def error_text(key, **opts) = I18n.t("deposit_responsibility_transfers.errors.#{key}", **opts)

    def failure(key, **opts) = Result.new(ok: false, error: error_text(key, **opts))
  end
end
