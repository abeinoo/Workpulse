module Finance
  # Cancels an unaccepted peer TillHandover. The handover must be pending
  # (not accepted, not already cancelled/rejected, not a self-deposit close
  # record). The current_holder is unchanged because the initiator still
  # holds the till — the pending record never transferred custody. Row-locked
  # against a concurrent accept/reject on the same handover.
  class TillHandoverCanceller
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    def initialize(handover_id, actor:, reason: nil)
      @handover_id = handover_id
      @actor       = actor
      @reason      = reason
    end

    def call
      @handover = TillHandover
                    .joins(:daily_reconciliation)
                    .where(daily_reconciliations: { business_id: @actor.business_id })
                    .find(@handover_id)

      # The pending? re-check and the mutation both happen inside the row lock
      # so a concurrent accept/reject on the same handover can never both
      # succeed — whichever request acquires the lock first wins; the other
      # reloads fresh state and cleanly fails the pending? check.
      result = nil
      @handover.with_lock do
        unless @handover.pending?
          result = Result.new(ok: false, error: I18n.t("till_handovers.errors.not_cancellable"))
          next
        end

        @handover.update!(
          cancelled_at:        Time.current,
          cancelled_by_id:     @actor.id,
          cancellation_reason: @reason
        )

        log_audit(
          actor:     @actor,
          auditable: @handover,
          action:    "cancel",
          metadata:  {
            daily_reconciliation_id: @handover.daily_reconciliation_id,
            from_user_id:            @handover.from_user_id,
            to_user_id:              @handover.to_user_id,
            reason:                  @reason
          }
        )

        result = Result.new(ok: true, handover: @handover)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
