module Requests
  # Applies an approved PunchCorrection request to the employee's AttendanceRecord.
  #
  # On success:
  #   - Snapshots original check_in_at / check_out_at onto the request.
  #   - Updates the attendance record's relevant punch time (check_in_at or check_out_at).
  #   - Recomputes late_minutes, early_leave_minutes, worked_minutes, status via RecordRecomputer.
  #   - Propagates the change to any open payroll entry via Payroll::PunchCorrectionApplier.
  #
  # Everything runs inside a single transaction so a partial failure leaves
  # both the attendance record and the request in their original state.
  class PunchCorrectionApplier
    Result = Struct.new(:success, :record, :error, keyword_init: true) do
      def success? = success
    end

    def self.call(request:)
      new(request).call
    end

    def initialize(request)
      @request = request
    end

    def call
      record = AttendanceRecord
                 .includes(shift_assignment: [ :rule_profile, { shift: :penalty_rules } ])
                 .find_by(user: @request.user, work_date: @request.requested_for_date)

      return failure("No attendance record found for #{@request.requested_for_date}") unless record

      applier_error = nil

      ActiveRecord::Base.transaction do
        @request.update_columns(
          original_check_in_at:  record.check_in_at,
          original_check_out_at: record.check_out_at
        )

        effective_dt = build_datetime(@request.approved_time || @request.proposed_time)

        case @request.correction_type
        when "missing_check_in", "wrong_check_in_time"
          record.check_in_at     = resolve_check_in(effective_dt, record.check_out_at)
          record.check_in_source = "admin_manual"
        when "missing_check_out", "wrong_check_out_time"
          record.check_out_at     = resolve_check_out(effective_dt, record.check_in_at)
          record.check_out_source = "admin_manual"
        end

        record.save!

        Attendance::RecordRecomputer.recompute!(record)
        record.save!

        Payroll::PunchCorrectionApplier.call(request: @request, record: record)
      end

      return failure(applier_error) if applier_error

      Result.new(success: true, record: record)
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.join(", "))
    rescue => e
      failure(e.message)
    end

    private

    # Combines the punch's actual calendar date with an "HH:MM" string in the
    # business timezone. Uses proposed_date (the real punch date) rather than
    # requested_for_date (the work/business date) so overnight punches that cross
    # midnight resolve to the correct moment — e.g. a check-out at 04:00 belonging
    # to the previous day's shift is stored on the next calendar day.
    def build_datetime(time_str)
      return nil if time_str.blank?

      hours, minutes = time_str.to_s.split(":").first(2).map(&:to_i)
      tz   = ActiveSupport::TimeZone[@request.user.business.timezone]
      date = @request.proposed_date || @request.requested_for_date
      tz.local(date.year, date.month, date.day, hours, minutes, 0)
    end

    # A corrected check-out must not land before the existing check-in. When the
    # anchor date (proposed_date, defaulting to the work_date) sits on an earlier
    # calendar day than the actual check-in — e.g. an overnight shift whose
    # work_date precedes the punch's real date, or a record whose check-in was
    # stored on a later day — build_datetime would otherwise produce a moment
    # before check_in_at and yield a negative worked_minutes. Roll the check-out
    # forward one day so it falls after the check-in (overnight crossing).
    def resolve_check_out(check_out_dt, existing_check_in)
      return check_out_dt if check_out_dt.nil? || existing_check_in.nil?

      check_out_dt < existing_check_in ? check_out_dt + 1.day : check_out_dt
    end

    # Symmetric guard for check-in corrections: a corrected check-in must not land
    # after the existing check-out. Roll it back one day when the anchor date
    # overshoots past the recorded check-out (overnight crossing).
    def resolve_check_in(check_in_dt, existing_check_out)
      return check_in_dt if check_in_dt.nil? || existing_check_out.nil?

      check_in_dt > existing_check_out ? check_in_dt - 1.day : check_in_dt
    end

    def failure(message)
      Result.new(success: false, error: message)
    end
  end
end
