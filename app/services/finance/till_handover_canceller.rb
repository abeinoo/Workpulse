module Finance
  # Cancels an unaccepted peer TillHandover. The handover must be pending
  # (not accepted, not already cancelled, not a self-deposit close record).
  # The current_holder is unchanged because the initiator still holds the till —
  # the pending record never transferred custody.
  class TillHandoverCanceller
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    def initialize(handover, actor:)
      @handover = handover
      @actor    = actor
    end

    def call
      unless @handover.pending?
        return Result.new(
          ok:    false,
          error: I18n.t("till_handovers.errors.not_cancellable")
        )
      end

      ActiveRecord::Base.transaction do
        @handover.update!(
          cancelled_at:    Time.current,
          cancelled_by_id: @actor.id
        )

        log_audit(
          actor:     @actor,
          auditable: @handover,
          action:    "cancel",
          metadata:  {
            daily_reconciliation_id: @handover.daily_reconciliation_id,
            from_user_id:            @handover.from_user_id,
            to_user_id:              @handover.to_user_id
          }
        )

        Result.new(ok: true, handover: @handover)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
