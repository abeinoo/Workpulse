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

    # Minutes worked beyond the scheduled shift duration plus the business-wide
    # overtime grace threshold. This is the SINGLE source of truth shared with
    # Salary::OvertimeCalculator so attendance status and payroll never diverge.
    #
    # Returns 0 when:
    #   - the rule profile disables overtime
    #   - the shift has no schedulable duration
    #   - worked time does not exceed scheduled + grace
    #
    # break_minutes from the rule profile are deducted from worked first.
    # overtime_grace_minutes is the business-level threshold (business.overtime_grace_minutes).
    def self.overtime_minutes(shift, worked_minutes, overtime_grace_minutes:, rule_profile: nil)
      return 0 if rule_profile && !rule_profile.overtime_enabled?
      return 0 unless shift

      scheduled = shift.duration_minutes.to_i
      return 0 if scheduled <= 0

      worked = worked_minutes.to_i
      return 0 if worked <= 0

      effective_worked = worked - rule_profile&.effective_break_minutes.to_i
      [ effective_worked - scheduled - overtime_grace_minutes.to_i, 0 ].max
    end

    # Final attendance outcome after grace periods, penalty thresholds, and overtime.
    # Inputs (late_minutes / early_leave_minutes) are already grace-adjusted.
    #
    #   shift:      used to resolve penalty-rule thresholds (nil → grace-only gating)
    #   completed:  both punches present? Open records can only be late/incomplete.
    #
    # Penalty-gated with grace fallback: Late / Early Departure flag only once the
    # minutes reach the LOWEST configured penalty threshold for that rule type. When a
    # shift has no penalty rules the threshold is 1 — i.e. any minute past grace flags
    # (grace-only fallback). So 10 min early under a 30-min first rule stays Present.
    #
    # Priority (single-valued status):
    #   late + early → late_early_leave
    #   late         → late        (late beats overtime)
    #   early        → early_leave  (early beats overtime)
    #   overtime     → overtime
    #   else         → present
    def self.derive_status(shift:, late_minutes:, early_leave_minutes:, overtime_minutes: 0, completed: true)
      late_flagged  = flagged?(late_minutes,        late_threshold(shift))
      early_flagged = flagged?(early_leave_minutes, early_threshold(shift))

      return late_flagged ? "late" : "incomplete" unless completed

      if late_flagged && early_flagged
        "late_early_leave"
      elsif late_flagged
        "late"
      elsif early_flagged
        "early_leave"
      elsif overtime_minutes.to_i > 0
        "overtime"
      else
        "present"
      end
    end

    # A minute value flags only when it is positive AND has reached the threshold.
    def self.flagged?(minutes, threshold)
      minutes.to_i.positive? && minutes.to_i >= threshold
    end
    private_class_method :flagged?

    # Lowest late-arrival penalty threshold, or 1 (grace fallback) when none configured.
    # Hour-based shifts have no late concept → Float::INFINITY so late never flags.
    # Filters the (possibly eager-loaded) association in Ruby to avoid N+1.
    def self.late_threshold(shift)
      return Float::INFINITY if shift.nil? || shift.hour_based?
      rules = shift.penalty_rules.select(&:late_arrival?)
      PenaltyRule.lowest_threshold(rules) || 1
    end
    private_class_method :late_threshold

    # Lowest early-leave penalty threshold, or 1 (grace fallback) when none configured.
    # Hour-based shifts apply ALL penalty rules to the hour shortfall (mirrors
    # PenaltyCalculator), so the threshold is the lowest across every rule.
    def self.early_threshold(shift)
      return 1 if shift.nil?
      rules = shift.hour_based? ? shift.penalty_rules.to_a : shift.penalty_rules.select(&:early_leave?)
      PenaltyRule.lowest_threshold(rules) || 1
    end
    private_class_method :early_threshold
  end
end
