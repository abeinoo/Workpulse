module Reports
  # Aggregates AttendanceRecords for a business/branch + date range.
  # Uses a single GROUP BY query to avoid loading every record into memory.
  class AttendanceSummary
    # branch_ids (optional) restricts a business-level summary to those
    # branches — the caller's authorized scope. nil means no restriction.
    def self.call(business:, branch: nil, branch_ids: nil, start_date:, end_date:)
      new(business: business, branch: branch, branch_ids: branch_ids, start_date: start_date, end_date: end_date).call
    end

    def initialize(business:, branch: nil, branch_ids: nil, start_date:, end_date:)
      @business   = business
      @branch     = branch
      @branch_ids = branch_ids
      @start_date = start_date
      @end_date   = end_date
    end

    def call
      rows = per_user_stats
      {
        branch_id:  @branch&.id,
        start_date: @start_date,
        end_date:   @end_date,
        totals:     aggregate_totals(rows),
        employees:  rows
      }
    end

    private

    STAT_KEYS = %i[
      total_days days_present late_days early_leave_days overtime_days absent_days
      total_late_minutes total_early_leave_minutes total_overtime_minutes total_worked_minutes
    ].freeze

    def per_user_stats
      base_scope
        .joins(:user)
        .group("attendance_records.user_id", "users.first_name", "users.last_name")
        .select(
          "attendance_records.user_id",
          "users.first_name",
          "users.last_name",
          "COUNT(*) AS total_days",
          "SUM(CASE WHEN attendance_records.status IN ('present','late','early_leave','late_early_leave','overtime') THEN 1 ELSE 0 END) AS days_present",
          "SUM(CASE WHEN attendance_records.status IN ('late','late_early_leave')        THEN 1 ELSE 0 END) AS late_days",
          "SUM(CASE WHEN attendance_records.status IN ('early_leave','late_early_leave') THEN 1 ELSE 0 END) AS early_leave_days",
          "SUM(CASE WHEN attendance_records.status = 'overtime'    THEN 1 ELSE 0 END) AS overtime_days",
          "SUM(CASE WHEN attendance_records.status = 'absent'      THEN 1 ELSE 0 END) AS absent_days",
          "SUM(COALESCE(overtime_minutes, 0))   AS total_overtime_minutes",
          "SUM(COALESCE(late_minutes, 0))        AS total_late_minutes",
          "SUM(COALESCE(early_leave_minutes, 0)) AS total_early_leave_minutes",
          "SUM(COALESCE(worked_minutes, 0))      AS total_worked_minutes"
        )
        .map { |r| build_row(r) }
    end

    def build_row(r)
      {
        user_id:                   r.user_id,
        full_name:                 "#{r.first_name} #{r.last_name}".strip,
        total_days:                r.total_days.to_i,
        days_present:              r.days_present.to_i,
        late_days:                 r.late_days.to_i,
        early_leave_days:          r.early_leave_days.to_i,
        overtime_days:             r.overtime_days.to_i,
        absent_days:               r.absent_days.to_i,
        total_late_minutes:        r.total_late_minutes.to_i,
        total_early_leave_minutes: r.total_early_leave_minutes.to_i,
        total_overtime_minutes:    r.total_overtime_minutes.to_i,
        total_worked_minutes:      r.total_worked_minutes.to_i
      }
    end

    def aggregate_totals(rows)
      STAT_KEYS.each_with_object({}) do |key, h|
        h[key] = rows.sum { |r| r[key] }
      end
    end

    def base_scope
      scope = AttendanceRecord.active.for_period(@start_date, @end_date)
      return scope.where(branch: @branch) if @branch

      scope = scope.for_business(@business)
      @branch_ids.nil? ? scope : scope.where(branch_id: @branch_ids)
    end
  end
end
