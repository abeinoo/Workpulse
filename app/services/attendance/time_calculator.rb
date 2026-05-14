module Attendance
  # Shared time arithmetic used by check-in, check-out, and adjustment services.
  module TimeCalculator
    # Minutes the employee was late relative to the shift start.
    # Returns 0 for hour-based shifts (no fixed start time penalty).
    def self.late_minutes(shift, check_in_at, branch)
      return 0 unless shift.fixed_time? && shift.start_time && check_in_at && branch

      tz         = branch.business.timezone_object
      local_time = check_in_at.in_time_zone(tz)
      shift_start = local_time.change(
        hour: shift.start_time.hour,
        min:  shift.start_time.min,
        sec:  0
      )

      delay = (local_time - shift_start).to_i / 60
      [ delay, 0 ].max
    end

    # Minutes the employee left early relative to the shift end or required hours.
    def self.early_leave_minutes(shift, check_out_at, worked_minutes, branch)
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
          # Checkout in the evening portion (hour >= shift start) means shift_end is next day
          checkout_hm = local_time.hour * 60 + local_time.min
          start_hm    = shift.start_time.hour * 60 + shift.start_time.min
          shift_end  += 1.day if checkout_hm >= start_hm
        end

        early = (shift_end - local_time).to_i / 60
        [ early, 0 ].max

      elsif shift.hour_based? && shift.required_hours
        required = (shift.required_hours * 60).to_i
        shortfall = required - worked_minutes.to_i
        [ shortfall, 0 ].max

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
