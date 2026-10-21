module Attendance
  # Attendance & Payroll implementation of the Workforce Shifts::AttendanceUsage
  # contract (registered in config/initializers/shift_attendance_usage.rb): whether
  # attendance has been recorded against a shift assignment (F2).
  #
  # Each operation is the code it replaces, unchanged: the model's EXISTS query
  # (no active scope — a soft-deleted record still counts) and the index's
  # correlated EXISTS column.
  module ShiftAssignmentUsage
    module_function

    # Was ShiftAssignment#has_attendance_records?'s query.
    def recorded_against?(assignment_id:) = AttendanceRecord.where(shift_assignment_id: assignment_id).exists?

    # Was ShiftAssignmentsController#index's select fragment (without its alias).
    def recorded_against_sql(assignment_column:)
      "EXISTS(SELECT 1 FROM attendance_records ar " \
        "WHERE ar.shift_assignment_id = #{assignment_column} LIMIT 1)"
    end
  end
end
