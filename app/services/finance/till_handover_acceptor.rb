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

    def initialize(handover, actor:, accepted_notes: nil)
      @handover       = handover
      @actor          = actor
      @accepted_notes = accepted_notes
    end

    def call
      return Result.new(ok: false, error: I18n.t("till_handovers.errors.not_acceptable")) unless @handover.pending?
      return Result.new(ok: false, error: I18n.t("till_handovers.errors.wrong_recipient")) unless @handover.to_user_id == @actor.id

      ActiveRecord::Base.transaction do
        @handover.update!(
          accepted_at:    Time.current,
          accepted_notes: @accepted_notes
        )

        @handover.daily_reconciliation.till_session.update!(current_holder: @actor)

        log_audit(actor: @actor, auditable: @handover, action: "accept",
                  metadata: { daily_reconciliation_id: @handover.daily_reconciliation_id })
      end

      Result.new(ok: true, handover: @handover)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
