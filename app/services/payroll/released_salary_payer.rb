module Payroll
  # "Pay Released Salary": records the payment of an entry withheld under a
  # Salary Payment Hold, after that hold was released. Never automatic — a
  # release only makes the amount payable. Recorded inside WorkPulse (who, when,
  # a note on how it was paid); no bank file.
  #
  # Refused while the hold is still active — that attempt is audited on the
  # hold — and for a withholding that is voided or already disbursed. Locks the
  # period, then the withholding (lock order period → entry), and re-checks
  # under both, so it cannot race Payroll::Reopener or a second payment.
  # Authorization (PayrollEntryPolicy#pay_released_salary?) is the caller's.
  class ReleasedSalaryPayer
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(actor:, withholding_id:, note:)
      @actor          = actor
      @withholding_id = withholding_id
      @note           = note.to_s.strip
    end

    def call
      return fail_with(t("note_required")) if @note.empty?

      withholding = SalaryPaymentWithholding.where(business_id: @actor.business_id).find(@withholding_id)
      error   = nil
      blocked = false

      ActiveRecord::Base.transaction do
        withholding.payroll_entry.payroll_period.lock!
        withholding.lock!
        hold = withholding.salary_payment_hold.reload

        error = if !withholding.live? then t("voided")
        elsif withholding.disbursed? then t("already_disbursed")
        elsif !withholding.payroll_entry.payroll_period.paid? then t("period_not_paid")
        elsif hold.active? then (blocked = true) && t("hold_active", reason: reason_label(hold))
        end
        raise ActiveRecord::Rollback if error

        withholding.update!(disbursed_at: Time.current, disbursed_by: @actor, disbursement_note: @note)
        log_audit!(actor: @actor, auditable: withholding.salary_payment_hold, action: "released_salary_paid",
                   metadata: { withholding_id: withholding.id, payroll_entry_id: withholding.payroll_entry_id,
                               user_id: hold.user_id, amount: withholding.amount.to_s, note: @note })
      end

      if error
        record_blocked_attempt(withholding) if blocked
        return Result.new(ok: false, record: withholding, error: error)
      end
      Result.new(ok: true, record: withholding)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: e.record, error: e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      fail_with(I18n.t("salary_payment_holds.errors.audit_failed"))
    end

    private

    # Outside the rolled-back transaction, so the attempt stays on record.
    def record_blocked_attempt(withholding)
      log_audit(actor: @actor, auditable: withholding.salary_payment_hold, action: "salary_payment_blocked",
                metadata: { path: "pay_released_salary", withholding_id: withholding.id,
                            payroll_entry_id: withholding.payroll_entry_id })
    end

    def reason_label(hold) = I18n.t("salary_payment_holds.reasons.#{hold.reason}")
    def fail_with(message) = Result.new(ok: false, error: message)
    def t(key, **) = I18n.t("salary_payment_holds.pay_released.errors.#{key}", **)
  end
end
