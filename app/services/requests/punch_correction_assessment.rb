module Requests
  # Read-only check of a punch correction against the employee's expected
  # attendance window (Attendance::PunchWindow) and the worked duration it
  # would produce (Attendance::DurationCheck). Never mutates anything.
  #
  # The judged moment is the one PunchCorrectionApplier would actually write:
  # the final date + time exactly as selected (no automatic day shifting), so a
  # legitimate after-midnight check-out is judged on the date it carries.
  #
  # Used by the request form (employee warning), the detail page (reviewer
  # warning) and Requests::Approver (server-side confirmation gate).
  class PunchCorrectionAssessment
    attr_reader :request, :window, :record, :date, :time_str, :effective_at

    def self.for(request, date: nil, time_str: nil)
      new(request, date: date, time_str: time_str)
    end

    # date / time_str: the punch to judge — the reviewer's selection at approval
    # (or while reviewing); default to the request's final punch (stored
    # reviewer selection, else the employee's proposal).
    def initialize(request, date: nil, time_str: nil)
      @request  = request
      @window   = Attendance::PunchWindow.for(user: request.user, work_date: request.requested_for_date)
      @record   = AttendanceRecord.find_by(user: request.user, work_date: request.requested_for_date)
      @date     = date || request.final_punch_date
      @time_str = time_str.presence || request.final_punch_time
      @effective_at = if legacy_approval?
        PunchCorrectionApplier.legacy_applied_punch_at(
          request: request, check_in_at: original_check_in_at, check_out_at: original_check_out_at
        )
      else
        PunchCorrectionApplier.effective_punch_at(request: request, date: @date, time_str: @time_str)
      end
    end

    def inside_window?
      window.cover?(effective_at)
    end

    # The judged final punch differs from the employee's proposal (reviewer
    # changed the date and/or time).
    def reviewer_modified?
      date != request.proposed_punch_date ||
        EmployeeRequest.normalized_clock(time_str) != EmployeeRequest.normalized_clock(request.proposed_time)
    end

    # Punches before this correction: the snapshot taken at approval once the
    # correction has been applied, otherwise the live attendance record.
    def original_check_in_at
      applied? ? request.original_check_in_at : record&.check_in_at
    end

    def original_check_out_at
      applied? ? request.original_check_out_at : record&.check_out_at
    end

    # Worked minutes the record would have with this correction applied;
    # nil when the other punch is missing.
    def projected_worked_minutes
      projected_record&.worked_minutes
    end

    # The attendance record as it would be with this correction applied,
    # recomputed by the same Attendance::RecordRecomputer the applier runs on
    # approval — on an unsaved copy, so nothing is persisted or altered.
    def projected_record
      return @projected_record if defined?(@projected_record)
      return @projected_record = nil unless record && effective_at

      copy = record.dup
      copy.check_in_at  = request.correction_field == :check_in  ? effective_at : original_check_in_at
      copy.check_out_at = request.correction_field == :check_out ? effective_at : original_check_out_at
      Attendance::RecordRecomputer.recompute!(copy)
      @projected_record = copy
    end

    # The corrected punches would put the check-out before the check-in. Never
    # auto-fixed by moving the date: approval is refused until the reviewer
    # selects the right date/time.
    def punch_order_invalid?
      return true if check_out_not_after_check_in?

      copy = projected_record
      return false unless copy&.check_in_at && copy.check_out_at

      copy.check_out_at < copy.check_in_at
    end

    # Check-out corrections (missing / wrong check-out): the corrected
    # check-out must be STRICTLY after the check-in. Compares full datetimes,
    # so an overnight check-out dated the next day (19:00 → 02:00) is valid.
    def check_out_not_after_check_in?
      return false unless request.correction_field == :check_out

      check_in_at = original_check_in_at
      return false unless check_in_at && effective_at

      effective_at <= check_in_at
    end

    # The message for an invalid punch order (see punch_order_invalid?).
    def punch_order_error
      key = check_out_not_after_check_in? ? "check_out_not_after_check_in" : "check_out_before_check_in"
      I18n.t("requests.errors.#{key}")
    end

    def duration_severity
      Attendance::DurationCheck.severity(projected_worked_minutes, business: request.user.business)
    end

    # Approval needs an explicit reviewer confirmation when the punch is
    # outside the window or would produce an abnormal worked duration.
    def requires_confirmation?
      !inside_window? || duration_severity.present?
    end

    def audit_metadata
      {
        final_punch_date:         date&.iso8601,
        final_punch_time:         time_str,
        effective_at:             effective_at&.iso8601,
        inside_window:            inside_window?,
        projected_worked_minutes: projected_worked_minutes,
        duration_severity:        duration_severity
      }
    end

    private

    def applied?
      request.original_check_in_at.present?
    end

    # Applied before reviewer-selected dates existed (see
    # PunchCorrectionApplier.legacy_applied_punch_at) — shown as it was written.
    def legacy_approval?
      applied? && request.approved_punch_at.nil?
    end
  end
end
