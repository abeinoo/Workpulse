module Payroll
  # Postpones one installment of an EmployeeObligation whose payroll period
  # has not been finalized/paid yet.
  #
  # Two modes (folded into EmployeeObligation#installment_schedule — see there):
  #   next_month:  the installment amount moves onto the immediately following
  #                month's installment (that month's due amount increases by
  #                exactly the postponed amount). Blocked if the following
  #                period falls outside the obligation's end window, or is
  #                already finalized/paid.
  #   extend_loan: the installment amount is relocated to a brand-new slot
  #                appended after the current end of the schedule. Every
  #                other installment is untouched.
  #
  # Neither mode changes total_amount, remaining_amount or installments_count —
  # postponement only changes WHEN an amount is due, never how much is owed.
  #
  # Eligibility is entirely period-status driven, not date driven — see
  # EmployeeObligation#postponable?/#period_finalized?. A period still in
  # draft, under_review or branch_review_completed may already carry a
  # deduction snapshot (payroll ran a preview calculation for it), but that
  # snapshot is fully mutable, exactly as Payroll::ObligationEditor already
  # treats it: postponing such an installment destroys its stale snapshot and
  # recalculates the affected payroll entries via Payroll::EntryRecalculator
  # so the payroll entry, the deduction snapshot and the obligation's
  # remaining_amount all stay in sync with the new schedule. Deliberately
  # does NOT gate on the obligation-wide payroll_locked? — a long-running
  # obligation with an already-paid month must still be able to postpone a
  # later, untouched installment.
  class ObligationInstallmentPostponer
    include AuditLoggable

    Result = Struct.new(:ok, :obligation, :postponement, :error, keyword_init: true) do
      def ok? = ok
    end

    def self.call(obligation_id:, business:, actor:, year:, month:, postponement_type:, reason: nil)
      new(obligation_id: obligation_id, business: business, actor: actor,
          year: year, month: month, postponement_type: postponement_type, reason: reason).call
    end

    def initialize(obligation_id:, business:, actor:, year:, month:, postponement_type:, reason: nil)
      @obligation_id     = obligation_id
      @business          = business
      @actor             = actor
      @year              = year.to_i
      @month             = month.to_i
      @postponement_type = postponement_type.to_s
      @reason            = reason.presence
    end

    def call
      obligation = EmployeeObligation.where(business: @business).find(@obligation_id)

      unless ObligationPostponement::TYPES.include?(@postponement_type)
        return err(obligation, I18n.t("admin.employee_obligations.postponement.invalid_type"))
      end
      unless obligation.postponable?(@year, @month)
        return err(obligation, I18n.t("admin.employee_obligations.postponement.not_eligible"))
      end

      target_year, target_month = target_for(obligation)
      if target_year.nil?
        return err(obligation, I18n.t("admin.employee_obligations.postponement.no_next_installment"))
      end

      postponement     = nil
      affected_periods = []

      ActiveRecord::Base.transaction do
        obligation.lock!

        # Re-check under the row lock: the eligibility state above is a
        # point-in-time read and could be stale by the time we hold the lock.
        raise ActiveRecord::Rollback unless obligation.postponable?(@year, @month)

        original_amount = original_amount_for(obligation, @year, @month)
        target_before   = obligation.scheduled_entry_for(target_year, target_month)&.dig(:amount).to_f
        target_after    = (target_before + original_amount).round(2)

        postponement = obligation.obligation_postponements.create!(
          postponement_type: @postponement_type,
          original_year:      @year,
          original_month:     @month,
          original_amount:    original_amount,
          target_year:        target_year,
          target_month:       target_month,
          amount:             original_amount,
          performed_by:       @actor,
          reason:             @reason
        )

        # A draft/under_review/branch_review_completed snapshot for either
        # period is now stale (the original's amount just moved away; the
        # target's needs to grow by that amount) — destroy it directly so
        # remaining_amount is correct immediately, regardless of whether a
        # full payroll entry exists yet for that period. (A finalized/paid
        # snapshot can never reach here — postponable?/period_finalized?
        # already refused it above.)
        [ [ @year, @month ], [ target_year, target_month ] ].each do |y, m|
          obligation.obligation_deductions
                    .joins(:payroll_period)
                    .where(payroll_periods: { period_year: y, period_month: m })
                    .where.not(payroll_periods: { status: EmployeeObligation::LOCKING_PERIOD_STATUSES })
                    .destroy_all
        end

        # Any of those periods that already has a full payroll entry for
        # this user needs its line items rebuilt too, so the entry (not just
        # the balance) reflects the new schedule — mirrors
        # Payroll::ObligationEditor#affected_periods.
        affected_periods = [
          reviewable_period_with_entry(obligation, @year, @month),
          reviewable_period_with_entry(obligation, target_year, target_month)
        ].compact.uniq

        log_audit(
          actor:     @actor,
          auditable: obligation,
          action:    "obligation_installment_postponed",
          changes:   {
            "installment_#{@year}_#{@month}"             => [ original_amount, 0.0 ],
            "installment_#{target_year}_#{target_month}" => [ target_before, target_after ]
          },
          metadata: {
            postponement_type: @postponement_type,
            original_period:   "#{@year}-#{@month}",
            target_period:     "#{target_year}-#{target_month}",
            amount:             original_amount,
            reason:             @reason,
            postponement_id:    postponement.id,
            recalculated_period_ids: affected_periods.map(&:id)
          }
        )
      end

      return err(obligation, I18n.t("admin.employee_obligations.postponement.not_eligible")) unless postponement&.persisted?

      affected_periods.sort_by { |p| [ p.period_year, p.period_month ] }.each do |period|
        Payroll::EntryRecalculator.call(user: obligation.user, period: period, triggered_by: @actor)
      end

      Result.new(ok: true, obligation: obligation.reload, postponement: postponement)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, obligation: obligation, error: e.record.errors.full_messages.to_sentence)
    end

    private

    # Prefer the actual amount payroll already computed for this period (if a
    # non-finalized draft snapshot exists) over the flat schedule projection —
    # the real snapshot is authoritative when one exists.
    def original_amount_for(obligation, year, month)
      snapshot = obligation.obligation_deductions.joins(:payroll_period)
                            .where(payroll_periods: { period_year: year, period_month: month })
                            .first
      return snapshot.deducted_amount.to_f if snapshot
      obligation.scheduled_entry_for(year, month)[:amount]
    end

    # The non-finalized PayrollPeriod for (year, month), if it already has an
    # entry for this obligation's user — mirrors Payroll::ObligationEditor's
    # affected_periods so a stale draft deduction gets rebuilt.
    def reviewable_period_with_entry(obligation, year, month)
      PayrollPeriod.for_business(@business)
                    .where.not(status: EmployeeObligation::LOCKING_PERIOD_STATUSES)
                    .joins(:payroll_entries)
                    .where(payroll_entries: { user_id: obligation.user_id })
                    .find_by(period_year: year, period_month: month)
    end

    def target_for(obligation)
      case @postponement_type
      when "next_month"
        ty, tm = obligation.next_period_for(@year, @month)
        return [ nil, nil ] unless obligation.within_window?(ty, tm)
        return [ nil, nil ] if obligation.period_finalized?(ty, tm)
        [ ty, tm ]
      when "extend_loan"
        last = obligation.installment_schedule.last
        obligation.next_period_for(last[:year], last[:month])
      end
    end

    def err(obligation, message)
      Result.new(ok: false, obligation: obligation, error: message)
    end
  end
end
