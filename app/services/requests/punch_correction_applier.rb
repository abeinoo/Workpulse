module Requests
  # Applies an approved PunchCorrection request to the employee's AttendanceRecord.
  #
  # On success:
  #   - Snapshots original check_in_at / check_out_at / check_in_source / check_out_source
  #     onto the request so cancellation can fully restore the pre-correction state.
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

    # The exact moment a correction applies: the final punch date + "HH:MM" in
    # the business timezone, taken literally — never shifted across midnight.
    # Defaults to the request's final punch (reviewer-selected date/time, else
    # the employee's proposal). Public so the pre-approval attendance-window and
    # duration checks judge the same datetime the applier writes.
    def self.effective_punch_at(request:, date: nil, time_str: nil)
      new(request).effective_punch_at(date: date || request.final_punch_date,
                                      time_str: time_str.presence || request.final_punch_time)
    end

    # What a correction approved BEFORE reviewer-selected dates existed
    # (approved_punch_at nil) actually wrote: the proposal rolled ±1 day against the
    # record's other punch. Used only to display those historical approvals
    # faithfully — new approvals never roll.
    def self.legacy_applied_punch_at(request:, check_in_at:, check_out_at:)
      new(request).legacy_applied_punch_at(check_in_at: check_in_at, check_out_at: check_out_at)
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
          original_check_in_at:      record.check_in_at,
          original_check_out_at:     record.check_out_at,
          original_check_in_source:  record.check_in_source,
          original_check_out_source: record.check_out_source
        )

        effective_dt = self.class.effective_punch_at(request: @request)

        case @request.correction_field
        when :check_in
          record.check_in_at     = effective_dt
          record.check_in_source = "admin_manual"
        when :check_out
          record.check_out_at     = effective_dt
          record.check_out_source = "admin_manual"
        end

        # The date is applied exactly as selected; a check-out before the
        # check-in is refused rather than silently moved to another day. A
        # check-out correction must land strictly after the check-in (full
        # datetime, so a next-day overnight check-out is valid).
        if record.check_in_at && record.check_out_at
          if @request.correction_field == :check_out && record.check_out_at <= record.check_in_at
            applier_error = I18n.t("requests.errors.check_out_not_after_check_in")
          elsif record.check_out_at < record.check_in_at
            applier_error = I18n.t("requests.errors.check_out_before_check_in")
          end
          raise ActiveRecord::Rollback if applier_error
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

    def effective_punch_at(date:, time_str:)
      build_datetime(date, time_str)
    end

    def legacy_applied_punch_at(check_in_at:, check_out_at:)
      dt = build_datetime(@request.proposed_punch_date, @request.final_punch_time)
      case @request.correction_field
      when :check_in  then resolve_check_in(dt, check_out_at)
      when :check_out then resolve_check_out(dt, check_in_at)
      end
    end

    private

    # Combines the punch's actual calendar date (not the work/business date) with
    # an "HH:MM" string in the business timezone. Overnight punches carry their
    # real date — e.g. a check-out at 04:00 for the previous day's shift is dated
    # the next calendar day by the employee or the reviewer.
    def build_datetime(date, time_str)
      return nil if date.nil? || time_str.blank?

      hours, minutes = time_str.to_s.split(":").first(2).map(&:to_i)
      tz = ActiveSupport::TimeZone[@request.user.business.timezone]
      tz.local(date.year, date.month, date.day, hours, minutes, 0)
    end

    # Legacy only (see legacy_applied_punch_at): the ±1-day roll that approvals
    # made before reviewer-selected dates existed. Rolled a check-out that fell
    # before the check-in forward one day.
    def resolve_check_out(check_out_dt, existing_check_in)
      return check_out_dt if check_out_dt.nil? || existing_check_in.nil?

      check_out_dt < existing_check_in ? check_out_dt + 1.day : check_out_dt
    end

    # Legacy only: the symmetric roll of a check-in past the check-out back one day.
    def resolve_check_in(check_in_dt, existing_check_out)
      return check_in_dt if check_in_dt.nil? || existing_check_out.nil?

      check_in_dt > existing_check_out ? check_in_dt - 1.day : check_in_dt
    end

    def failure(message)
      Result.new(success: false, error: message)
    end
  end
end
