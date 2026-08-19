module Finance
  # Corrects the operational amounts (cash/visa/instapay/other) on the
  # handover that closed the accounting day. This is the single entry point
  # for editing Day Close amounts — it never touches TillHandover/TillSession
  # directly from outside the Finance::TillHandoverCreator calculation path.
  #
  # Requires a non-blank reason. Each changed payment method is logged as a
  # before/after diff in the audit log so the audit trail is complete.
  #
  # May only be called while the reconciliation is closed — not yet deposited
  # or verified.
  class DayCloseEditor
    include AuditLoggable

    Result = Struct.new(:ok, :error, keyword_init: true) { def ok? = ok }

    # amounts: { payment_method_id => { collected_amount: "...", refund_amount: "..." } }
    def initialize(daily_reconciliation, actor:, amounts:, reason:)
      @dr      = daily_reconciliation
      @actor   = actor
      @amounts = amounts || {}
      @reason  = reason
    end

    def call
      if @dr.verified?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.cannot_edit_after_verification"))
      end

      if @dr.deposited?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.cannot_edit_after_deposit"))
      end

      unless @dr.closed?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.day_close_not_closed"))
      end

      if @reason.blank?
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.day_close_edit_reason_required"))
      end

      handover = @dr.day_close_handover
      unless handover
        return Result.new(ok: false,
                          error: I18n.t("finance.daily_reconciliations.errors.day_close_not_closed"))
      end

      ActiveRecord::Base.transaction do
        changes = {}

        @amounts.each do |pm_id, attrs|
          ha = handover.amounts.operational.find_by(payment_method_id: pm_id.to_i)
          next unless ha

          new_collected = attrs[:collected_amount].to_s.presence&.to_d || ha.collected_amount
          new_refund    = attrs[:refund_amount].to_s.presence&.to_d    || ha.refund_amount

          old_collected = ha.collected_amount
          old_refund    = ha.refund_amount

          next if old_collected == new_collected && old_refund == new_refund

          ha.update!(collected_amount: new_collected, refund_amount: new_refund)

          changes[ha.payment_method_name] = {
            collected: [ old_collected.to_s, new_collected.to_s ],
            refund:    [ old_refund.to_s,    new_refund.to_s    ]
          }
        end

        if changes.any?
          Finance::TillHandoverCreator.sync_session_amounts!(@dr, handover)
          Finance::EmployeeReconciliationSummarizer.new(@dr).persist!

          log_audit(
            actor:     @actor,
            auditable: handover,
            action:    "edit_day_close_amounts",
            changes:   changes,
            metadata:  { reason: @reason }
          )
        end

        Result.new(ok: true)
      end
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
