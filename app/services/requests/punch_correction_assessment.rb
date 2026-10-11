module Requests
  # Read-only check of a punch correction against the employee's expected
  # attendance window and the worked duration it would produce. Never mutates
  # anything. The attendance facts come from Attendance & Payroll through the
  # Workforce contract Requests::PunchCorrectionEffects.correction_facts
  # (Pilot 10 M3); this class names nothing from Attendance & Payroll.
  #
  # The judged moment is the one PunchCorrectionApplier would actually write:
  # the final date + time exactly as selected (no automatic day shifting), so a
  # legitimate after-midnight check-out is judged on the date it carries.
  #
  # Used by the request form (employee warning), the detail page (reviewer
  # warning) and Requests::Approver (server-side confirmation gate).
  class PunchCorrectionAssessment
    # The attendance window as the views read it: plain values, no Attendance &
    # Payroll objects. shift is nil without an assigned shift.
    Window = Struct.new(:work_date, :shift, :shift_starts_at, :shift_ends_at, keyword_init: true)
    Shift  = Struct.new(:name, :required_hours, keyword_init: true)

    attr_reader :request, :date, :time_str, :effective_at

    def self.for(request, date: nil, time_str: nil)
      new(request, date: date, time_str: time_str)
    end

    # date / time_str: the punch to judge — the reviewer's selection at approval
    # (or while reviewing); default to the request's final punch (stored
    # reviewer selection, else the employee's proposal).
    def initialize(request, date: nil, time_str: nil)
      @request  = request
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
      facts.inside_window?
    end

    def window
      @window ||= Window.new(
        work_date:       request.requested_for_date,
        shift:           facts.shift_name && Shift.new(name: facts.shift_name, required_hours: facts.shift_required_hours),
        shift_starts_at: facts.shift_starts_at,
        shift_ends_at:   facts.shift_ends_at
      )
    end

    # The judged final punch differs from the employee's proposal (reviewer
    # changed the date and/or time).
    def reviewer_modified?
      date != request.proposed_punch_date ||
        EmployeeRequest.normalized_clock(time_str) != EmployeeRequest.normalized_clock(request.proposed_time)
    end

    # Punches before this correction: the snapshot taken at approval once the
    # correction has been applied, otherwise the live attendance record.
    # The applied snapshot (legacy approvals included) is the request's own data;
    # otherwise the live attendance record's punches.
    def original_check_in_at
      applied? ? request.original_check_in_at : facts.check_in_at
    end

    def original_check_out_at
      applied? ? request.original_check_out_at : facts.check_out_at
    end

    # Worked minutes the record would have with this correction applied,
    # recomputed by Attendance & Payroll on an unsaved copy; nil when the other
    # punch is missing.
    def projected_worked_minutes
      facts.projected_worked_minutes
    end

    # The corrected punches would put the check-out before the check-in. Never
    # auto-fixed by moving the date: approval is refused until the reviewer
    # selects the right date/time.
    def punch_order_invalid?
      return true if check_out_not_after_check_in?
      return false unless facts.record_found? && effective_at

      check_in_at  = request.correction_field == :check_in  ? effective_at : original_check_in_at
      check_out_at = request.correction_field == :check_out ? effective_at : original_check_out_at
      return false unless check_in_at && check_out_at

      check_out_at < check_in_at
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
      facts.duration_severity
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

    # One contract call per assessment, after effective_at is known (a legacy
    # approval's effective_at needs only the request's snapshot).
    def facts
      @facts ||= PunchCorrectionEffects.correction_facts(
        request: request, field: request.correction_field, effective_at: effective_at, baseline: baseline
      )
    end

    # The punches before an applied correction, as persisted on the request.
    def baseline
      return unless applied?

      PunchCorrectionEffects::Snapshot.new(
        check_in_at:      request.original_check_in_at,
        check_out_at:     request.original_check_out_at,
        check_in_source:  request.original_check_in_source,
        check_out_source: request.original_check_out_source
      )
    end

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
