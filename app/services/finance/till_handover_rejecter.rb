module Finance
  # Rejects a pending peer TillHandover on behalf of the named recipient.
  # The handover must be pending (not accepted, not already cancelled/
  # rejected, not a self-deposit close record). The current_holder is
  # unchanged because custody never transferred to the intended recipient —
  # rejecting simply confirms it never will. Row-locked against a concurrent
  # accept/cancel on the same handover.
  #
  # Structurally mirrors Finance::TillHandoverCanceller (mark-dead-in-place,
  # no compensating record) — never Finance::TillHandoverReverser, which
  # operates on an already-accepted handover and must create a compensating
  # transaction because custody actually moved.
  class TillHandoverRejecter
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

      # Super Admin (business owner) is never blocked by recipient assignment.
      unless @actor.owner? || @handover.to_user_id == @actor.id
        return Result.new(ok: false, error: I18n.t("till_handovers.errors.wrong_recipient"))
      end

      result = nil
      @handover.with_lock do
        unless @handover.pending?
          result = Result.new(ok: false, error: I18n.t("till_handovers.errors.not_rejectable"))
          next
        end

        @handover.update!(
          rejected_at:      Time.current,
          rejected_by_id:   @actor.id,
          rejection_reason: @reason
        )

        log_audit(
          actor:     @actor,
          auditable: @handover,
          action:    "reject",
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
