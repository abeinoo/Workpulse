module Attendance
  # Smart single-endpoint punch service for biometric device integration.
  #
  # Every valid punch is logged and is evidence for its work date; the record's
  # check-in / check-out are re-derived from all of the work date's punches —
  # mobile and device alike — by Attendance::PunchAggregator (earliest punch =
  # check-in, latest = check-out when the day has a departure; see there), and
  # every derived value with them, so the arrival order never matters.
  #
  # Log action (what the punch did; never decides what counts):
  #   - check_in / check_in_updated / check_out → the punch became that value
  #   - rejected_spam → no effect, within SPAM_WINDOW of a previous logged punch
  #   - recorded      → no effect otherwise (inside the day, a second entry scan,
  #                     a manually set value) — kept as evidence
  # Refusals (never evidence):
  #   - No active shift assignment    → rejected_no_assignment
  #   - Work date in a finalized / paid payroll period → rejected_payroll_locked
  #   - Lost a concurrent first-punch insert → the whole punch is retried once
  class PunchService
    SPAM_WINDOW = 60.seconds

    Result = Struct.new(:success, :action, :record, :log, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(employee:, punched_at:, business:, device: nil, ip_address: nil, raw_payload: nil)
      @employee    = employee
      @punched_at  = punched_at
      @business    = business
      @device      = device
      @ip_address  = ip_address
      @raw_payload = raw_payload
    end

    def call
      unless @employee.allow_biometric_attendance?
        log = record_punch!(action: "rejected_not_allowed")
        return Result.new(success: false, action: "rejected_not_allowed", log: log,
                          error: I18n.t("api.punch.biometric_attendance_not_allowed"))
      end

      # One transaction from the payroll-period lock to the punch log (TD-T-1): the
      # period row is held FOR SHARE until commit, so Payroll::Approver (FOR UPDATE)
      # cannot finalize or pay between the lock check and the attendance write, and
      # the attendance change and its log are committed together or not at all.
      # #process returns the Result (no return across the transaction block).
      begin
        punch_transaction
      rescue ActiveRecord::RecordNotUnique
        # A concurrent first punch of the same employee and work date won the
        # (user_id, work_date) unique index. This attempt rolled back entirely (no
        # record, no log), so the whole punch runs once more on the committed state
        # — period guard included — and gets the outcome it would have had if it
        # had arrived second. A second conflict propagates (no loop).
        punch_transaction
      end
    end

    private

    # requires_new: a real transaction when none is open (as from the API); a
    # savepoint inside a caller's transaction, so a unique violation rolls back to
    # it and the retry does not run inside an aborted PostgreSQL transaction.
    def punch_transaction
      ActiveRecord::Base.transaction(requires_new: true) { process }
    end

    # Lock order: payroll period (FOR SHARE) → attendance record → punch log — the
    # "period first" order of Payroll::Approver, Payroll::OvertimeRecalculator and
    # Attendance::PunchCorrectionEffects. Concurrent punches share the period lock.
    def process
      @work_date  = BusinessDay.work_date_for(@punched_at, context: @business)

      # Finalized / paid payroll is immutable: a punch whose work date belongs to
      # a locked period changes nothing (SEC-P12-1, D-T4).
      if payroll_locked?
        log = record_punch!(action: "rejected_payroll_locked")
        return Result.new(success: false, action: "rejected_payroll_locked", log: log,
                          error: I18n.t("api.punch.payroll_locked"))
      end

      @assignment = Shifts::AssignmentResolver.for(user: @employee, date: @work_date)

      unless @assignment
        log = record_punch!(action: "rejected_no_assignment")
        return Result.new(success: false, action: "rejected_no_assignment", log: log,
                          error: I18n.t("api.punch.no_shift_assignment"))
      end

      # Locked: concurrent punches of the employee's work date are aggregated one
      # after the other, each seeing the other's committed log (BUG-002).
      record = AttendanceRecord.lock.find_or_initialize_by(user: @employee, work_date: @work_date)
      if record.new_record?
        record.assign_attributes(branch: @assignment.branch, shift_assignment: @assignment, date: @work_date)
      end

      aggregator = Attendance::PunchAggregator.new(
        record, business:   @business,
                assignment: record.shift_assignment || @assignment,
                branch:     record.branch || @assignment.branch
      )
      effect = aggregator.apply!(Attendance::PunchAggregator::Punch.device(@punched_at))

      save_record(record, aggregator, action: effect || (spam_punch? ? "rejected_spam" : "recorded"))
    end

    # Every accepted punch's log is linked to the record — a duplicate's too,
    # which is what makes it evidence (Attendance::PunchAggregator). A duplicate
    # still answers with no record (API contract: "attendance_record": null).
    def save_record(record, aggregator, action:)
      if record.save
        aggregator.log_reconstructed_punches!
        log = record_punch!(action: action, record: record)
        Result.new(success: true, action: action, record: (record unless action == "rejected_spam"), log: log)
      else
        error_msg = record.errors.full_messages.join(", ")
        Rails.logger.warn("[PunchService] Save failed device=#{@device&.id} employee=#{@employee&.id}: #{error_msg}")
        log = record_punch!(action: "error", error: error_msg)
        Result.new(success: false, action: "error", record: record, log: log, error: error_msg)
      end
    end

    # The canonical payroll period of the work date's calendar month (unique per
    # business + year + month — the row Payroll::Approver locks), read FOR SHARE
    # inside #call's transaction (TD-T-1): a finalization in progress is waited
    # for and its committed status seen; a finalization started afterwards waits
    # for this punch. No period yet → not locked (nothing to lock).
    def payroll_locked?
      PayrollPeriod.lock("FOR SHARE").find_by(
        business: @business, period_year: @work_date.year, period_month: @work_date.month
      )&.locked? || false
    end

    def spam_punch?
      BiometricPunchLog
        .where(employee: @employee, business: @business)
        .where.not(action: BiometricPunchLog::NOT_SPAM_ACTIONS)
        .where(punched_at: (@punched_at - SPAM_WINDOW)..(@punched_at + SPAM_WINDOW))
        .exists?
    end

    def record_punch!(action:, record: nil, error: nil)
      BiometricPunchLog.create!(
        business:          @business,
        biometric_device:  @device,
        employee:          @employee,
        attendance_record: record,
        work_date:         @work_date,
        punched_at:        @punched_at,
        received_at:       Time.current,
        source:            "biometric",
        action:            action,
        ip_address:        @ip_address,
        raw_payload:       @raw_payload&.to_json,
        error_message:     error
      )
    end
  end
end
