module Payroll
  # Re-calculates one employee's PayrollEntry for a non-locked (editable) period
  # after an attendance change (edit or manual entry).
  #
  # The rebuild follows the same pattern as Regenerator, except the entry row
  # itself is updated in place rather than destroyed and recreated — its id,
  # created_at, and any external references stay stable across recalculations:
  #   1. Capture management decisions that survive regeneration (overtime
  #      override, deduction waivers — see Payroll::DeductionWaiverPersistence).
  #   2. Destroy the user's obligation-deduction snapshots for this period so
  #      balances are correctly restored before re-deducting.
  #   3. Run EntryCalculator to recompute the entry (and rebuild its line items)
  #      in place from current attendance.
  #   4. Re-apply the preserved decisions.
  #
  # Returns ok: true even when the user has no salary profile (entry will be nil).
  # Errors are surfaced through the Result struct so the attendance write that
  # triggered this can never fail because of a payroll recalculation problem.
  class EntryRecalculator
    Result = Struct.new(:ok, :entry, :error, keyword_init: true) do
      def ok? = ok
    end

    def self.call(user:, period:, triggered_by:)
      new(user: user, period: period, triggered_by: triggered_by).call
    end

    # Recalculates every non-locked period that already has an entry for this
    # user. Used when salary/insurance configuration changes outside the
    # normal attendance-write path — see Salary::ProfileUpdater and
    # Employee::InsuranceProfileUpdater — so the change is reflected in every
    # currently editable period, not just the next full generation.
    def self.recalculate_all_open_periods_for(user:, triggered_by:)
      PayrollPeriod
        .for_business(user.business)
        .where.not(status: %w[finalized paid])
        .joins(:payroll_entries)
        .where(payroll_entries: { user_id: user.id })
        .distinct
        .find_each do |period|
          call(user: user, period: period, triggered_by: triggered_by)
        end
    end

    def initialize(user:, period:, triggered_by:)
      @user         = user
      @period       = period
      @business     = period.business
      @triggered_by = triggered_by
    end

    def call
      return Result.new(ok: true, entry: nil) if @period.locked?

      existing          = load_existing_entry
      previous_snapshot = existing&.financial_snapshot
      saved_override    = capture_overtime_override(existing)
      saved_waivers      = Payroll::DeductionWaiverPersistence.capture(
        existing&.payroll_line_items || PayrollLineItem.none
      )
      saved_cancellations = Payroll::AdditionCancellationPersistence.capture(
        existing&.payroll_line_items || PayrollLineItem.none
      )

      entry = ActiveRecord::Base.transaction do
        destroy_obligation_snapshots
        Payroll::EntryCalculator.call(period: @period, user: @user, business: @business, entry: existing)
      end

      if entry
        reapply_overtime_override(entry, saved_override) if saved_override
        waivers_touched      = Payroll::DeductionWaiverPersistence.reapply_to_entry(entry, saved_waivers)
        cancellations_touched = Payroll::AdditionCancellationPersistence.reapply_to_entry(entry, saved_cancellations)
        entry.recalculate_totals! if waivers_touched || cancellations_touched
        # EntryCalculator writes base_salary/insurance/salary_type directly
        # (not via recalculate_totals!), so this is the only place that can
        # catch those fields changing for an existing employee.
        entry.mark_needs_review!(previous_snapshot) if previous_snapshot
      end

      Rails.logger.info(
        "[Payroll::EntryRecalculator] period=#{@period.id} #{@period.period_label} " \
        "user=#{@user.id} triggered_by=#{@triggered_by.id} entry=#{entry&.id}"
      )
      Result.new(ok: true, entry: entry)
    end

    private

    def load_existing_entry
      @period.payroll_entries
             .includes(:payroll_line_items)
             .find_by(user: @user)
    end

    # Destroy this user's ObligationDeduction snapshots for the period so that
    # EntryCalculator can re-create them. Each snapshot's before_destroy callback
    # restores the obligation's remaining_amount, keeping balances accurate.
    def destroy_obligation_snapshots
      @period.obligation_deductions
             .joins(:employee_obligation)
             .where(employee_obligations: { user_id: @user.id })
             .destroy_all
    end

    def capture_overtime_override(entry)
      return nil unless entry&.overtime_overridden?
      {
        mode:               entry.overtime_override_mode,
        approved_minutes:   entry.approved_overtime_minutes,
        approved_pay:       entry.approved_overtime_pay,
        calculated_minutes: entry.calculated_overtime_minutes,
        calculated_pay:     entry.calculated_overtime_pay,
        reason:             entry.overtime_override_reason,
        overridden_by_id:   entry.overtime_overridden_by_id,
        overridden_at:      entry.overtime_overridden_at
      }
    end

    # Mirror of Regenerator#reapply_overtime_overrides for a single entry.
    def reapply_overtime_override(entry, prev)
      new_calc_minutes = entry.calculated_overtime_minutes.to_i
      new_calc_pay     = entry.calculated_overtime_pay.to_f
      return if new_calc_minutes.zero? || new_calc_pay <= 0

      if prev[:mode] == "amount"
        approved_pay     = [ prev[:approved_pay].to_f, new_calc_pay ].min.round(2)
        approved_minutes = (new_calc_minutes * approved_pay / new_calc_pay).round
      else
        approved_minutes = [ prev[:approved_minutes].to_i, new_calc_minutes ].min
        approved_pay     = (new_calc_pay * approved_minutes / new_calc_minutes).round(2)
      end

      stale = new_calc_minutes != prev[:calculated_minutes].to_i ||
              (new_calc_pay - prev[:calculated_pay].to_f).abs >= 0.01

      entry.update!(
        overtime_override_mode:    prev[:mode],
        approved_overtime_minutes: approved_minutes,
        approved_overtime_pay:     approved_pay,
        overtime_override_reason:  prev[:reason],
        overtime_overridden_by_id: prev[:overridden_by_id],
        overtime_overridden_at:    prev[:overridden_at],
        overtime_override_stale:   stale
      )
      entry.recalculate_totals!
    end
  end
end
