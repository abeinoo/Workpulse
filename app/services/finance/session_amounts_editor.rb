module Finance
  # Edits TillSessionAmount records after the day is closed.
  # Requires a non-blank notes field. Each changed field is logged as a
  # before/after diff in the audit log so the audit trail is complete.
  # May only be called on a closed or deposited reconciliation.
  class SessionAmountsEditor
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    # amounts: { payment_method_id => { collected_amount: "...", refund_amount: "..." } }
    def initialize(daily_reconciliation, actor:, amounts:, notes:)
      @dr      = daily_reconciliation
      @actor   = actor
      @amounts = amounts || {}
      @notes   = notes
    end

    def call
      if @dr.verified?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.already_verified"))
      end

      unless @dr.closed? || @dr.deposited?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.not_closed"))
      end

      if @notes.blank?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.edit_notes_required"))
      end

      ActiveRecord::Base.transaction do
        changes = {}

        @amounts.each do |pm_id, attrs|
          sa = @dr.session_amounts.find_by(payment_method_id: pm_id.to_i)
          next unless sa

          new_collected = attrs[:collected_amount].to_s.presence&.to_d || sa.collected_amount
          new_refund    = attrs[:refund_amount].to_s.presence&.to_d    || sa.refund_amount

          old_collected = sa.collected_amount
          old_refund    = sa.refund_amount

          next if old_collected == new_collected && old_refund == new_refund

          sa.update!(collected_amount: new_collected, refund_amount: new_refund)

          changes[sa.payment_method_name] = {
            collected: [ old_collected.to_s, new_collected.to_s ],
            refund:    [ old_refund.to_s,    new_refund.to_s    ]
          }
        end

        if changes.any?
          log_audit(
            actor:     @actor,
            auditable: @dr,
            action:    "edit_session_totals",
            changes:   changes,
            metadata:  { notes: @notes }
          )
        end

        Result.new(ok: true)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
