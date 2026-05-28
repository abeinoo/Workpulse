module Attendance
  # Shared time arithmetic used by check-in, check-out, adjustment, and recompute services.
  #
  # rule_profile (ShiftRuleProfile | nil) — when present its grace windows and
  # expected_work_hours override the shift defaults before returning values.
  # Priority: rule_profile > shift defaults.
  module TimeCalculator
    # Minutes the employee was late relative to the shift start.
    # Grace from the rule profile is subtracted before returning (floor 0).
    # Returns 0 for hour-based shifts (no fixed start time penalty).
    def self.late_minutes(shift, check_in_at, branch, rule_profile: nil)
      return 0 unless shift.fixed_time? && shift.start_time && check_in_at && branch

      tz          = branch.business.timezone_object
      local_time  = check_in_at.in_time_zone(tz)
      shift_start = local_time.change(
        hour: shift.start_time.hour,
        min:  shift.start_time.min,
        sec:  0
      )

      raw_delay = (local_time - shift_start).to_i / 60
      grace     = rule_profile&.effective_late_grace.to_i
      [ raw_delay - grace, 0 ].max
    end

    # Minutes the employee left early relative to the shift end or required hours.
    # Grace from the rule profile is subtracted before returning (floor 0).
    # expected_work_hours on the profile overrides shift.required_hours for hour-based shifts.
    def self.early_leave_minutes(shift, check_out_at, worked_minutes, branch, rule_profile: nil)
      return 0 unless check_out_at

      if shift.fixed_time? && shift.end_time
        tz         = branch.business.timezone_object
        local_time = check_out_at.in_time_zone(tz)
        shift_end  = local_time.change(
          hour: shift.end_time.hour,
          min:  shift.end_time.min,
          sec:  0
        )

        if shift.overnight?
          checkout_hm = local_time.hour * 60 + local_time.min
          start_hm    = shift.start_time.hour * 60 + shift.start_time.min
          shift_end  += 1.day if checkout_hm >= start_hm
        end

        raw_early = (shift_end - local_time).to_i / 60
        grace     = rule_profile&.effective_early_leave_grace.to_i
        [ raw_early - grace, 0 ].max

      elsif shift.hour_based?
        required_hours = rule_profile&.expected_work_hours.presence || shift.required_hours
        return 0 unless required_hours

        required  = (required_hours * 60).to_i
        shortfall = required - worked_minutes.to_i
        grace     = rule_profile&.effective_early_leave_grace.to_i
        [ shortfall - grace, 0 ].max

      else
        0
      end
    end

    def self.derive_status(late_minutes, early_leave_minutes)
      if late_minutes.to_i > 0
        "late"
      elsif early_leave_minutes.to_i > 0
        "early_leave"
      else
        "present"
      end
    end
  end
end
