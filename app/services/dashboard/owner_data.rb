module Dashboard
  # Collects all data needed by the Owner (super-admin) dashboard.
  # All attendance totals are derived from a single DB read per concern so
  # the dashboard never generates N+1 queries regardless of team size.
  #
  # Date arithmetic uses the business's configured timezone so that "today"
  # is correct regardless of the server's UTC offset.
  class OwnerData
    Result = Struct.new(
      :stats,
      :trends,
      :active_now,
      :branch_snapshots,
      :today_records_by_user,
      :recent_payroll_periods,
      :missing_checkouts,
      keyword_init: true
    )

    def self.call(business)
      new(business).call
    end

    def initialize(business)
      @business   = business
      tz          = business.timezone_object
      @today      = Time.current.in_time_zone(tz).to_date
      @yesterday  = @today - 1
    end

    def call
      Result.new(
        stats:                  compute_stats,
        trends:                 compute_trends,
        active_now:             active_now_list,
        branch_snapshots:       branch_snapshots,
        today_records_by_user:  today_records_by_user,
        recent_payroll_periods: recent_payroll_periods,
        missing_checkouts:      missing_checkouts
      )
    end

    private

    attr_reader :business, :today, :yesterday

    # ── Shared base queries (memoized so each runs once) ──────────────────────

    def today_records
      @today_records ||= AttendanceRecord
        .for_business(business)
        .where(date: today)
        .includes(:branch, user: { profile_photo_attachment: :blob })
    end

    def yesterday_records
      @yesterday_records ||= AttendanceRecord
        .for_business(business)
        .where(date: yesterday)
    end

    def today_records_by_user
      @today_records_by_user ||= today_records.index_by(&:user_id)
    end

    def employee_ids
      @employee_ids ||= business.users.where(active: true).pluck(:id)
    end

    # ── Stats ─────────────────────────────────────────────────────────────────

    def compute_stats
      records = today_records.to_a

      checked_in  = records.count { |r| r.check_in_at.present? }
      checked_out = records.count { |r| r.checked_out? }
      late_count  = records.count { |r| r.status == "late" }
      active_now  = records.count { |r| r.check_in_at.present? && !r.checked_out? }
      total       = employee_ids.size
      # Employees with no record today are considered absent for dashboard display
      absent      = [ total - records.size, 0 ].max
      att_pct     = total.zero? ? 0 : (checked_in * 100.0 / total).round
      on_time     = checked_in - late_count
      ontime_pct  = total.zero? ? 0 : ([ on_time, 0 ].max * 100.0 / total).round

      worked_minutes = records.filter_map(&:worked_minutes)
      avg_work_mins  = worked_minutes.empty? ? nil : (worked_minutes.sum / worked_minutes.size.to_f).round

      {
        total_employees:   total,
        branches:          business.branches.active.count,
        checked_in:        checked_in,
        checked_out:       checked_out,
        late_count:        late_count,
        active_now:        active_now,
        absent:            absent,
        pending_requests:  EmployeeRequest.for_business(business).pending.count,
        attendance_pct:    att_pct,
        on_time_pct:       ontime_pct,
        avg_work_mins:     avg_work_mins
      }
    end

    # ── Trends (delta vs yesterday) ───────────────────────────────────────────

    def compute_trends
      yest  = yesterday_records.to_a
      today = today_records.to_a

      yest_checked_in = yest.count { |r| r.check_in_at.present? }
      yest_late       = yest.count { |r| r.status == "late" }
      today_checked_in = today.count { |r| r.check_in_at.present? }
      today_late       = today.count { |r| r.status == "late" }

      busiest = branch_snapshots.max_by { |s| s[:active_now] }

      {
        attendance_delta: today_checked_in - yest_checked_in,
        late_delta:       today_late - yest_late,
        busiest_branch:   busiest&.dig(:branch),
        busiest_active:   busiest&.dig(:active_now).to_i
      }
    end

    # ── Who is Here Now ───────────────────────────────────────────────────────

    def active_now_list
      today_records
        .select { |r| r.check_in_at.present? }
        .sort_by { |r| [ r.checked_out? ? 1 : 0, r.check_in_at ] }
    end

    # ── Branch snapshots ──────────────────────────────────────────────────────
    # Two queries total for all branches — one GROUP BY on attendance, one
    # GROUP BY on user_branches.

    def branch_snapshots
      @branch_snapshots ||= begin
        attendance_by_branch = AttendanceRecord
          .for_business(business)
          .where(date: today)
          .group(:branch_id)
          .select(
            "branch_id",
            "COUNT(*)                                            AS total_attended",
            "SUM(CASE WHEN status='late'         THEN 1 ELSE 0 END) AS late_count",
            "SUM(CASE WHEN check_out_at IS NOT NULL THEN 1 ELSE 0 END) AS checked_out_count",
            "SUM(CASE WHEN check_in_at IS NOT NULL AND check_out_at IS NULL THEN 1 ELSE 0 END) AS active_now_count"
          ).index_by(&:branch_id)

        emp_counts_by_branch = User
          .joins(:user_branches)
          .where(users: { business_id: business.id, active: true })
          .group("user_branches.branch_id")
          .count

        business.branches.active.order(:name).map do |branch|
          stats    = attendance_by_branch[branch.id]
          emp_cnt  = emp_counts_by_branch[branch.id] || 0
          attended = stats&.total_attended.to_i
          late     = stats&.late_count.to_i
          active   = stats&.active_now_count.to_i
          absent   = [ emp_cnt - attended, 0 ].max

          {
            branch:     branch,
            employees:  emp_cnt,
            attended:   attended,
            late:       late,
            active_now: active,
            absent:     absent,
            att_pct:    emp_cnt.zero? ? 0 : (attended * 100.0 / emp_cnt).round
          }
        end
      end
    end

    # ── Supporting data ───────────────────────────────────────────────────────

    def recent_payroll_periods
      @recent_payroll_periods ||= PayrollPeriod
        .where(business: business)
        .order(period_year: :desc, period_month: :desc)
        .limit(4)
    end

    def missing_checkouts
      @missing_checkouts ||= AttendanceRecord
        .for_business(business)
        .where(date: yesterday, status: "incomplete")
        .includes(:user)
        .limit(5)
    end
  end
end
