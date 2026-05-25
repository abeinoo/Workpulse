module Attendance
  # Single-query KPI aggregation for the attendance index dashboard strip.
  # Accepts any scoped relation (respects Pundit policy scope).
  class DailyStats
    Result = Struct.new(
      :checked_in, :working_now, :checked_out,
      :late_count, :absent_count, :total_worked_minutes,
      keyword_init: true
    )

    def self.call(scope:, today:)
      row = scope.where(work_date: today).pick(
        Arel.sql("COUNT(*) FILTER (WHERE check_in_at IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE check_in_at IS NOT NULL AND check_out_at IS NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE check_out_at IS NOT NULL)"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'late')"),
        Arel.sql("COUNT(*) FILTER (WHERE status = 'absent')"),
        Arel.sql("COALESCE(SUM(worked_minutes), 0)")
      ) || Array.new(6, 0)

      Result.new(
        checked_in:           row[0].to_i,
        working_now:          row[1].to_i,
        checked_out:          row[2].to_i,
        late_count:           row[3].to_i,
        absent_count:         row[4].to_i,
        total_worked_minutes: row[5].to_i
      )
    end
  end
end
