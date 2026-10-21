module Shifts
  # Workforce read contract: has attendance been recorded against a shift
  # assignment? (F2 — module-boundaries.md §13 cycle F2, §12.1 inversion rule).
  #
  # Workforce owns shift assignments and the rule that one may be hard-deleted
  # only while no attendance references it (ShiftAssignment#deletable?,
  # ShiftAssignmentPolicy#destroy?, bulk delete). Attendance records are
  # Attendance & Payroll's. Workforce defines WHAT it needs; Attendance & Payroll
  # implements it and registers the implementation at boot
  # (config/initializers/shift_attendance_usage.rb). This module names nothing
  # from Attendance & Payroll.
  #
  # A handler must respond to:
  #   recorded_against?(assignment_id:)
  #     — true when any attendance record (soft-deleted ones included) references
  #       the assignment; false otherwise. One query.
  #   recorded_against_sql(assignment_column:)
  #     — the same question as a SQL boolean expression correlated to
  #       `assignment_column` (e.g. "shift_assignments.id"), for selecting it as a
  #       column of a shift-assignment list in the same query (no per-row query).
  module AttendanceUsage
    OPERATIONS = %i[recorded_against? recorded_against_sql].freeze

    # A qualified column reference — the only input interpolated into SQL.
    COLUMN = /\A[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*\z/

    # Raised when the question is asked before any handler is registered.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Shifts::AttendanceUsage handler is registered")
      end

      def recorded_against?(assignment_id:)
        value = handler.recorded_against?(assignment_id: assignment_id)
        return value if value == true || value == false

        raise ArgumentError, "#{handler}.recorded_against? returned #{value.class}, expected true or false"
      end

      def recorded_against_sql(assignment_column:)
        raise ArgumentError, "not a qualified column: #{assignment_column.inspect}" unless COLUMN.match?(assignment_column.to_s)

        sql = handler.recorded_against_sql(assignment_column: assignment_column.to_s)
        return sql if sql.is_a?(String) && sql.include?(assignment_column.to_s)

        raise ArgumentError, "#{handler}.recorded_against_sql returned #{sql.inspect}, expected SQL correlated to #{assignment_column}"
      end
    end
  end
end
