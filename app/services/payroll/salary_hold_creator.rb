module Payroll
  # Places an employee on Salary Payment Hold. The hold blocks payment only:
  # it never touches payroll entries, salary profiles, attendance or any
  # calculation. At most one active hold per employee — the database's partial
  # unique index decides a concurrent second attempt.
  #
  # Authorization (SalaryPaymentHoldPolicy#create?) is the caller's; the
  # employee is loaded inside the actor's business.
  class SalaryHoldCreator
    include AuditLoggable

    Result = Struct.new(:ok, :record, :error, keyword_init: true) { def ok? = ok }

    def initialize(actor:, user_id:, reason:, effective_from:, notes: nil)
      @actor          = actor
      @user_id        = user_id
      @reason         = reason.to_s
      @effective_from = effective_from
      @notes          = notes.to_s.strip.presence
    end

    def call
      employee = User.where(business_id: @actor.business_id).find(@user_id)
      return fail_with(t("errors.already_active")) if SalaryPaymentHold.active.exists?(user_id: employee.id)

      hold = nil
      ActiveRecord::Base.transaction do
        hold = SalaryPaymentHold.create!(business_id: @actor.business_id, user: employee, reason: @reason,
                                         effective_from: @effective_from, notes: @notes, created_by: @actor)
        log_audit!(actor: @actor, auditable: hold, action: "salary_hold_created",
                   metadata: { user_id: employee.id, reason: hold.reason,
                               effective_from: hold.effective_from.iso8601, notes: hold.notes }.compact)
      end
      Result.new(ok: true, record: hold)
    rescue ActiveRecord::RecordNotUnique
      fail_with(t("errors.already_active"))
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, record: e.record, error: e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      fail_with(t("errors.audit_failed"))
    end

    private

    def fail_with(message) = Result.new(ok: false, error: message)
    def t(key) = I18n.t("salary_payment_holds.#{key}")
  end
end
