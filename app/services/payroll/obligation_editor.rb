module Payroll
  # Edits an EmployeeObligation's schedule (start/end period, amounts) and keeps
  # every payroll period it has already touched consistent with the new schedule.
  #
  # Blocked entirely once any deduction belongs to a finalized or paid period —
  # see EmployeeObligation#payroll_locked?. Draft, under_review and
  # branch_review_completed periods stay editable: every period that currently
  # holds a deduction for this obligation, plus every non-locked period that the
  # old or the new schedule covers (the "window" either version could apply to),
  # is rebuilt via Payroll::EntryRecalculator so obligation eligibility, the
  # deduction snapshot, remaining balance and the payroll entry all stay in sync.
  class ObligationEditor
    include AuditLoggable

    Result = Struct.new(:ok, :obligation, :error, keyword_init: true) do
      def ok? = ok
    end

    def self.call(obligation_id:, business:, actor:, attrs:)
      new(obligation_id: obligation_id, business: business, actor: actor, attrs: attrs).call
    end

    def initialize(obligation_id:, business:, actor:, attrs:)
      @obligation_id = obligation_id
      @business      = business
      @actor         = actor
      @attrs         = attrs
    end

    def call
      obligation = EmployeeObligation.where(business: @business).find(@obligation_id)
      return err(obligation, I18n.t("admin.employee_obligations.locked_for_edit")) if obligation.payroll_locked?

      before = obligation.slice(:start_month, :start_year, :end_month, :end_year,
                                 :total_amount, :installment_amount)
      previous_user = obligation.user
      periods = affected_periods(obligation)

      unless obligation.update(@attrs.merge(installments_count: derive_installments_count(obligation)))
        return err(obligation, obligation.errors.full_messages.to_sentence)
      end

      # Reassigned to another employee (AP-D5): the previous employee's open
      # entries must lose the deduction and the new employee's must gain it.
      # The obligation's open snapshots (none can be finalized/paid here — see
      # payroll_locked? above) are removed first, restoring the balance, then
      # both employees are rebuilt, each only where they already have an entry.
      reassigned = obligation.user_id != previous_user.id
      users      = [ obligation.user ]
      if reassigned
        users << previous_user
        periods = (periods + affected_periods(obligation)).uniq(&:id)
        obligation.obligation_deductions.joins(:payroll_period)
                  .where.not(payroll_periods: { status: EmployeeObligation::LOCKING_PERIOD_STATUSES })
                  .destroy_all
      end

      periods.sort_by { |p| [ p.period_year, p.period_month ] }.each do |period|
        users.each do |user|
          next if reassigned && !period.payroll_entries.exists?(user_id: user.id)

          Payroll::EntryRecalculator.call(user: user, period: period, triggered_by: @actor)
        end
      end

      after   = obligation.slice(:start_month, :start_year, :end_month, :end_year,
                                   :total_amount, :installment_amount)
      changes = before.each_with_object({}) { |(k, v), h| h[k] = [ v, after[k] ] if v != after[k] }

      log_audit(
        actor:     @actor,
        auditable: obligation,
        action:    "obligation_edited",
        changes:   changes,
        metadata:  { recalculated_period_ids: periods.map(&:id) }
      )

      Result.new(ok: true, obligation: obligation)
    end

    private

    # Every period this obligation currently has a deduction snapshot in, plus every
    # reviewable period (with an existing entry for this user) that the old or the
    # new start/end window covers — so periods that gain or lose eligibility under
    # the new schedule are recalculated even if they had no deduction yet.
    def affected_periods(obligation)
      existing = obligation.obligation_deductions.map(&:payroll_period)

      candidates = PayrollPeriod.for_business(@business)
                                 .where.not(status: EmployeeObligation::LOCKING_PERIOD_STATUSES)
                                 .joins(:payroll_entries)
                                 .where(payroll_entries: { user_id: obligation.user_id })
                                 .distinct

      old_window = candidates.select do |p|
        covers?(p, obligation.start_year, obligation.start_month, obligation.end_year, obligation.end_month)
      end
      new_window = candidates.select do |p|
        covers?(p, @attrs[:start_year].to_i, @attrs[:start_month].to_i,
                @attrs[:end_year].presence&.to_i, @attrs[:end_month].presence&.to_i)
      end

      (existing + old_window + new_window).uniq(&:id)
    end

    def covers?(period, start_year, start_month, end_year, end_month)
      after_start = (start_year < period.period_year) ||
                    (start_year == period.period_year && start_month <= period.period_month)
      before_end  = (end_year.nil? && end_month.nil?) ||
                    (end_year > period.period_year) ||
                    (end_year == period.period_year && end_month >= period.period_month)
      after_start && before_end
    end

    def derive_installments_count(obligation)
      total       = @attrs[:total_amount].presence&.to_f       || obligation.total_amount.to_f
      installment = @attrs[:installment_amount].presence&.to_f || obligation.installment_amount.to_f
      return 1 if total <= 0 || installment <= 0
      (total / installment).ceil
    end

    def err(obligation, message)
      Result.new(ok: false, obligation: obligation, error: message)
    end
  end
end
