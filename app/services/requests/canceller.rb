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
  #     punch_correction : Attendance & Payroll restores the attendance record from
  #                        the request's snapshot and recalculates the payroll entry
  #                        through the Workforce contract Requests::PunchCorrectionEffects
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
        # Punch corrections lock the request row first (lock order: request →
        # payroll period) and re-check the committed state against what the
        # caller saw, so a stale cancellation can neither cancel twice nor skip
        # the rollback of an approval committed since it was loaded. Salary
        # advances do the same (F-A1): Approver#pay locks the same row, so a
        # payment committed since this copy was loaded is never overwritten by
        # a cancellation (its Advance would stay active and be deducted).
        if @request.punch_correction? || @request.salary_advance?
          rollback_error = locked_state_error(prior_status)
          raise ActiveRecord::Rollback if rollback_error
        end

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

    # Locks and reloads the request, then repeats cancel's own checks on the
    # committed state. A status other than the one the caller acted on (e.g. a
    # pending request approved meanwhile) is refused: who may cancel depends on
    # it (EmployeeRequestPolicy#cancel?). nil when it may still be cancelled.
    def locked_state_error(observed_status)
      @request.lock!
      return I18n.t("requests.errors.already_cancelled") if @request.cancelled?
      return I18n.t("requests.errors.cannot_cancel_paid") if @request.paid?
      return I18n.t("requests.errors.cannot_cancel") unless cancellable_status? && @request.status == observed_status

      nil
    end

    def rollback_approval_effects
      case @request.request_type
      when "salary_advance"    then ok   # Advance only created at pay step
      when "late_permission",
           "early_leave"       then revert_permission_payroll_effect
      when "punch_correction"  then revert_punch_correction_effect
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

    # ── Punch correction effect (Pilot 10 M4-2) ────────────────────────────────
    #
    # Attendance & Payroll restores the attendance record from the snapshot
    # persisted on the request and brings its payroll back, through the Workforce
    # contract, inside this cancel transaction. Refusals keep the request
    # approved with the messages cancellation has always shown; an invalid record
    # is reported with its messages; any other error rolls the cancel back.
    def revert_punch_correction_effect
      result = Requests::PunchCorrectionEffects.correction_cancelled(
        request: @request, field: @request.correction_field, snapshot: punch_snapshot, actor: @cancelled_by
      )

      case result
      when :no_attendance_record then err(I18n.t("requests.errors.no_attendance_record"))
      when :payroll_locked       then err(I18n.t("requests.errors.cannot_cancel_finalized"))
      else ok
      end
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    # The punches before the correction, as persisted on the request at approval.
    def punch_snapshot
      Requests::PunchCorrectionEffects::Snapshot.new(
        check_in_at:      @request.original_check_in_at,
        check_out_at:     @request.original_check_out_at,
        check_in_source:  @request.original_check_in_source,
        check_out_source: @request.original_check_out_source
      )
    end

    def ok
      Result.new(success: true, request: @request)
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
