module Attendance
  # Smart single-endpoint punch service for biometric device integration.
  #
  # Rules:
  #   - First punch of the work_date  → check_in
  #   - Earlier punch than check_in   → update check_in (keeps earliest)
  #   - Later punch than check_in     → set/update check_out (keeps latest)
  #   - Punch within SPAM_WINDOW of a previous logged punch → rejected_spam
  #   - No active shift assignment    → rejected_no_assignment
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

      @work_date  = BusinessDay.work_date_for(@punched_at, context: @business)
      @assignment = Shifts::AssignmentFinder.for(user: @employee, date: @work_date)

      unless @assignment
        log = record_punch!(action: "rejected_no_assignment")
        return Result.new(success: false, action: "rejected_no_assignment", log: log,
                          error: I18n.t("api.punch.no_shift_assignment"))
      end

      if spam_punch?
        log = record_punch!(action: "rejected_spam")
        return Result.new(success: true, action: "rejected_spam", log: log)
      end

      record = AttendanceRecord.find_or_initialize_by(user: @employee, work_date: @work_date)

      if record.new_record? || record.check_in_at.nil?
        perform_check_in(record)
      elsif @punched_at <= record.check_in_at
        perform_check_in_update(record)
      else
        perform_check_out(record)
      end
    end

    private

    def perform_check_in(record)
      late_mins = Attendance::TimeCalculator.late_minutes(
        @assignment.shift, @punched_at, @assignment.branch
      )

      record.assign_attributes(
        branch:           @assignment.branch,
        shift_assignment: @assignment,
        date:             @work_date,
        check_in_at:      @punched_at,
        late_minutes:     late_mins,
        status:           late_mins > 0 ? "late" : "incomplete"
      )

      save_record(record, action: "check_in")
    end

    def perform_check_in_update(record)
      # Recalculate lateness based on the updated (earlier) check_in
      shift  = record.shift_assignment&.shift || @assignment.shift
      branch = record.branch || @assignment.branch
      late_mins = Attendance::TimeCalculator.late_minutes(shift, @punched_at, branch)

      record.assign_attributes(
        check_in_at:  @punched_at,
        late_minutes: late_mins,
        status:       late_mins > 0 ? "late" : record.status
      )

      save_record(record, action: "check_in_updated")
    end

    def perform_check_out(record)
      # Only update if this punch is strictly later than the current check_out
      if record.check_out_at.present? && @punched_at <= record.check_out_at
        log = record_punch!(action: "rejected_spam")
        return Result.new(success: true, action: "rejected_spam", log: log)
      end

      shift  = record.shift_assignment&.shift || @assignment.shift
      branch = record.branch || @assignment.branch

      worked_mins      = ((@punched_at - record.check_in_at) / 60).to_i
      early_leave_mins = Attendance::TimeCalculator.early_leave_minutes(
        shift, @punched_at, worked_mins, branch
      )
      status = Attendance::TimeCalculator.derive_status(record.late_minutes, early_leave_mins)

      record.assign_attributes(
        check_out_at:        @punched_at,
        worked_minutes:      worked_mins,
        early_leave_minutes: early_leave_mins,
        status:              status
      )

      save_record(record, action: "check_out")
    end

    def save_record(record, action:)
      if record.save
        log = record_punch!(action: action, record: record)
        Result.new(success: true, action: action, record: record, log: log)
      else
        error_msg = record.errors.full_messages.join(", ")
        log = record_punch!(action: "error", error: error_msg)
        Result.new(success: false, action: "error", record: record, log: log, error: error_msg)
      end
    end

    def spam_punch?
      BiometricPunchLog
        .where(employee: @employee, business: @business)
        .where.not(action: %w[rejected_no_assignment error])
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
