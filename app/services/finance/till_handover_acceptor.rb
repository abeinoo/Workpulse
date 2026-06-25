module Finance
  # Accepts a pending transfer handover on behalf of the named recipient.
  # After acceptance the recipient becomes the current till holder.
  class TillHandoverAcceptor
    include AuditLoggable

    Result = Struct.new(:ok, :handover, :error, keyword_init: true) { def ok? = ok }

    def initialize(handover, actor:)
      @handover = handover
      @actor    = actor
    end

    def call
      unless @handover.transfer? && @handover.pending?
        return Result.new(ok: false, error: I18n.t("till_handovers.errors.not_acceptable"))
      end

      unless @handover.to_user_id == @actor.id
        return Result.new(ok: false, error: I18n.t("till_handovers.errors.wrong_recipient"))
      end

      ActiveRecord::Base.transaction do
        @handover.update!(accepted_at: Time.current)
        log_audit(
          actor:     @actor,
          auditable: @handover,
          action:    "accept",
          metadata:  { business_date: @handover.business_date.to_s }
        )
      end

      Result.new(ok: true, handover: @handover)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
