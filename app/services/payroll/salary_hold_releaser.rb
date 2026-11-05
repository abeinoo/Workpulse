module Payroll
  # Releases a Salary Payment Hold: records who released it, when and why. It
  # pays nothing and recalculates nothing — the entries withheld under the hold
  # simply become payable through Payroll::ReleasedSalaryPayer.
  #
  # The hold row is locked and re-checked, so two concurrent releases release
  # it once. Authorization (SalaryPaymentHoldPolicy#release?) is the caller's.
  class SalaryHoldReleaser
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(actor:, hold_id:, release_reason: nil)
      @actor          = actor
      @hold_id        = hold_id
      @release_reason = release_reason.to_s.strip.presence
    end

    def call
      hold  = SalaryPaymentHold.where(business_id: @actor.business_id).find(@hold_id)
      error = nil

      ActiveRecord::Base.transaction do
        hold.lock!
        if hold.released?
          error = I18n.t("salary_payment_holds.errors.already_released")
          raise ActiveRecord::Rollback
        end

        hold.update!(released_at: Time.current, released_by: @actor, release_reason: @release_reason)
        log_audit!(actor: @actor, auditable: hold, action: "salary_hold_released",
                   metadata: { user_id: hold.user_id, release_reason: @release_reason,
                               outstanding_withholding_ids: hold.salary_payment_withholdings.outstanding.order(:id).ids }.compact)
      end
      return Result.new(ok: false, record: hold, error: error) if error

      Result.new(ok: true, record: hold)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: e.record, error: e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      Result.new(ok: false, error: I18n.t("salary_payment_holds.errors.audit_failed"))
    end
  end
end
