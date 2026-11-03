module Attendance
  # Re-derives every value an AttendanceRecord computes from its check-in /
  # check-out pair — late, worked, early-leave and overtime minutes and the
  # status — so nothing computed from an earlier pair survives a change to
  # either punch. Shared by Attendance::PunchAggregator (device and mobile
  # punches) and Attendance::AdjustmentService (manager edits).
  #
  # Rule profile (grace / expected work hours) — kept exactly as each source
  # applied it before the punch sources were unified; the cross-source policy is
  # an open decision (see docs/quality/deferred-bugs.md, BUG-040):
  #   - mobile_grace: true (punch paths): late minutes use the profile's late
  #     grace when the effective check-in is a mobile punch, and early-leave
  #     minutes use its early-leave grace and expected work hours when the
  #     effective check-out is a mobile punch — what CheckInService /
  #     CheckOutService computed; device punches never had it.
  #   - mobile_grace: false (manager edits): no grace on either field, as
  #     AdjustmentService always computed.
  # Overtime always honours the profile (break minutes, overtime enabled).
  # Without a check-out the checkout-derived values are reset and the status is
  # that of an open record.
  #
  # Mutates the record in memory; the caller saves it.
  module DerivedFields
    module_function

    def apply!(record, assignment: record.shift_assignment, branch: record.branch, mobile_grace: false)
      shift        = assignment&.shift
      rule_profile = assignment&.rule_profile
      business     = branch&.business || record.user.business
      late_profile  = rule_profile if mobile_grace && record.check_in_source == "mobile"
      early_profile = rule_profile if mobile_grace && record.check_out_source == "mobile"

      late_mins = shift ? TimeCalculator.late_minutes(shift, record.check_in_at, branch, rule_profile: late_profile) : 0

      if record.check_in_at && record.check_out_at
        worked_mins      = ((record.check_out_at - record.check_in_at) / 60).to_i
        early_leave_mins = shift ? TimeCalculator.early_leave_minutes(shift, record.check_out_at, worked_mins, branch,
                                                                      rule_profile: early_profile) : 0
        overtime_mins    = TimeCalculator.overtime_minutes(
          shift, worked_mins,
          overtime_grace_minutes: business.overtime_grace_minutes.to_i,
          rule_profile:           rule_profile
        )
      else
        worked_mins      = nil
        early_leave_mins = 0
        overtime_mins    = 0
      end

      record.assign_attributes(
        late_minutes:        late_mins,
        worked_minutes:      worked_mins,
        early_leave_minutes: early_leave_mins,
        overtime_minutes:    overtime_mins,
        status:              TimeCalculator.derive_status(
          shift:               shift,
          late_minutes:        late_mins,
          early_leave_minutes: early_leave_mins,
          overtime_minutes:    overtime_mins,
          completed:           !worked_mins.nil?
        )
      )
    end
  end
end
