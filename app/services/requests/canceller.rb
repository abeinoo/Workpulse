module Requests
  # Cancels an EmployeeRequest and rolls back every business effect that its
  # approval created, returning the system to the exact pre-approval state.
  #
  # Cancellable transitions
  #   pending  → cancelled  (all types)  — no side-effects to reverse
  #   approved → cancelled  (all types)  — side-effects reversed per type:
  #
  #     salary_advance   : no rollback — Advance is only created on pay, not approve
  #     late_permission  : the payroll effect is reverted by Attendance & Payroll
  #     early_leave        through the Workforce contract Requests::PermissionPayrollEffects
  #                        (refused while the payroll period is finalized / paid)
  #     punch_correction : restores check_in_at/out + sources on AttendanceRecord,
  #                        recomputes the record, and re-propagates to open payroll
  #
  # Blocked transitions
  #   paid      → not cancellable (Advance already created / funds disbursed)
  #   rejected  → not cancellable
  #   finalized / paid payroll period → not cancellable for permission and punch types
  class Canceller
    include AuditLoggable

    Result = Struct.new(:success, :request, :error, keyword_init: true) do
      def success? = success
    end

    def self.cancel(request:, cancelled_by:, reason:)
      new(request: request, cancelled_by: cancelled_by, reason: reason).cancel
    end

    def initialize(request:, cancelled_by:, reason:)
      @request      = request
      @cancelled_by = cancelled_by
      @reason       = reason
    end

    def cancel
      return err(I18n.t("requests.errors.already_cancelled")) if @request.cancelled?
      return err(I18n.t("requests.errors.cannot_cancel_paid")) if @request.paid?
      return err(I18n.t("requests.errors.cannot_cancel"))      unless cancellable_status?

      prior_status   = @request.status
      rollback_error = nil

      ActiveRecord::Base.transaction do
        if @request.approved?
          result = rollback_approval_effects
          unless result.success?
            rollback_error = result.error
            raise ActiveRecord::Rollback
          end
        end

        @request.update!(
          status:               "cancelled",
          cancelled_by:         @cancelled_by,
          cancelled_at:         Time.current,
          cancellation_reason:  @reason
        )

        log_audit(
          actor:     @cancelled_by,
          auditable: @request,
          action:    "cancel",
          changes:   { status: [ prior_status, "cancelled" ] },
          metadata:  { reason: @reason, request_type: @request.request_type }.compact
        )
      end

      return err(rollback_error) if rollback_error

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    private

    def cancellable_status?
      @request.status.in?(%w[pending approved])
    end

    def rollback_approval_effects
      case @request.request_type
      when "salary_advance"    then ok   # Advance only created at pay step
      when "late_permission",
           "early_leave"       then revert_permission_payroll_effect
      when "punch_correction"  then rollback_punch_correction
      else ok
      end
    end

    # ── Permission payroll effect (late_permission / early_leave) ──────────────
    #
    # Attendance & Payroll reverts it through the Workforce contract, inside this
    # cancel transaction. :refused (the payroll period is finalized or paid)
    # keeps the request approved, as before; an invalid line item raises
    # ActiveRecord::RecordInvalid, which #cancel turns into the same failed Result.
    def revert_permission_payroll_effect
      case Requests::PermissionPayrollEffects.permission_cancelled(request: @request)
      when :refused then err(I18n.t("requests.errors.cannot_cancel_finalized"))
      else ok
      end
    end

    # ── Punch correction rollback ─────────────────────────────────────────────
    #
    # Restores check_in_at/out and their source fields from the snapshots taken
    # at approval time, then recomputes the record and re-propagates to payroll.
    def rollback_punch_correction
      record = AttendanceRecord
                 .includes(shift_assignment: [ :rule_profile, { shift: :penalty_rules } ])
                 .find_by(user: @request.user, work_date: @request.requested_for_date)

      return err(I18n.t("requests.errors.no_attendance_record")) unless record

      period = covering_period
      if period&.finalized? || period&.paid?
        return err(I18n.t("requests.errors.cannot_cancel_finalized"))
      end

      case @request.correction_type
      when "missing_check_in", "wrong_check_in_time"
        record.check_in_at     = @request.original_check_in_at
        record.check_in_source = @request.original_check_in_source
      when "missing_check_out", "wrong_check_out_time"
        record.check_out_at     = @request.original_check_out_at
        record.check_out_source = @request.original_check_out_source
      end

      record.save!
      Attendance::RecordRecomputer.recompute!(record)
      record.save!

      rollback_punch_payroll(record)

      ok
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    # Updates or recreates penalty line items in the open payroll entry to match
    # the restored attendance record. Mirrors Payroll::PunchCorrectionApplier but
    # also handles the case where the correction had destroyed a line item (it
    # would only update existing items, never recreate).
    def rollback_punch_payroll(record)
      period = covering_period
      return unless period && !period.finalized? && !period.paid?

      entry = PayrollEntry.find_by(payroll_period: period, user: @request.user)
      return unless entry

      daily_rate = daily_rate_for(entry)

      restore_penalty_line_item(entry, record, "late_penalty",        record.late_minutes.to_i,        daily_rate)
      restore_penalty_line_item(entry, record, "early_leave_penalty", record.early_leave_minutes.to_i, daily_rate)
      entry.recalculate_totals!
    end

    def restore_penalty_line_item(entry, record, item_type, raw_minutes, daily_rate)
      line_item = entry.payroll_line_items.find_by(
        source_type: "AttendanceRecord",
        source_id:   record.id,
        item_type:   item_type
      )

      if raw_minutes == 0
        line_item&.destroy!
        return
      end

      full_amount = compute_penalty(record, daily_rate, item_type, raw_minutes)

      if full_amount.round(2) == 0.0
        line_item&.destroy!
      elsif line_item
        line_item.update!(amount: full_amount.round(2), original_minutes: raw_minutes)
      else
        type_label = item_type == "late_penalty" ? "Late arrival" : "Early leave"
        entry.payroll_line_items.create!(
          item_type:        item_type,
          amount:           full_amount.round(2),
          description:      "#{type_label} #{record.work_date}",
          source_type:      "AttendanceRecord",
          source_id:        record.id,
          original_minutes: raw_minutes
        )
      end
    end

    # ── Shared helpers ─────────────────────────────────────────────────────────

    def covering_period
      PayrollPeriod.where(
        business:     @request.user.business,
        period_month: @request.requested_for_date.month,
        period_year:  @request.requested_for_date.year
      ).first
    end

    def daily_rate_for(entry)
      Salary::DailyRateCalculator.for(
        user:     @request.user,
        business: @request.user.business,
        date:     entry.payroll_period.period_start
      ).daily_rate
    end

    def compute_penalty(record, daily_rate, item_type, minutes)
      if item_type == "late_penalty"
        result = Attendance::PenaltyCalculator.calculate(
          record:                record,
          daily_salary:          daily_rate,
          late_minutes_override: minutes
        )
        -result.late_penalty
      else
        result = Attendance::PenaltyCalculator.calculate(
          record:                       record,
          daily_salary:                 daily_rate,
          early_leave_minutes_override: minutes
        )
        -result.early_leave_penalty
      end
    end

    def ok
      Result.new(success: true, request: @request)
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
