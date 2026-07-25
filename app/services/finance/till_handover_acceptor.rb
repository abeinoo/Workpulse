module Finance
  # Accepts a pending TillHandover on behalf of the named recipient.
  #
  # On acceptance:
  #   - handover is stamped with accepted_at and accepted_notes
  #   - TillSession.current_holder is updated to the recipient
  #   - TillHandoverAmount records are locked (no further changes allowed)
  class TillHandoverAcceptor
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    def initialize(handover_id, actor:, accepted_notes: nil)
      @handover_id    = handover_id
      @actor          = actor
      @accepted_notes = accepted_notes
    end

    def call
      @handover = TillHandover
                    .joins(:daily_reconciliation)
                    .where(daily_reconciliations: { business_id: @actor.business_id })
                    .includes(daily_reconciliation: :till_session)
                    .find(@handover_id)

      # Super Admin (business owner) is never blocked by recipient assignment.
      unless @actor.owner? || @handover.to_user_id == @actor.id
        return Result.new(ok: false, error: I18n.t("till_handovers.errors.wrong_recipient"))
      end

      # The pending? re-check and the mutation both happen inside the row lock
      # so a concurrent cancel/reject/accept on the same handover can never
      # both succeed — whichever request acquires the lock first wins; the
      # other reloads fresh state and cleanly fails the pending? check.
      result = nil
      @handover.with_lock do
        unless @handover.pending?
          result = Result.new(ok: false, error: I18n.t("till_handovers.errors.not_acceptable"))
          next
        end

        @handover.update!(
          accepted_at:    Time.current,
          accepted_notes: @accepted_notes
        )

        @handover.daily_reconciliation.till_session.update!(current_holder: @actor)

        log_audit(actor: @actor, auditable: @handover, action: "accept",
                  metadata: { daily_reconciliation_id: @handover.daily_reconciliation_id })

        result = Result.new(ok: true, handover: @handover)
      end
      result
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
