class OperationsDashboardController < ApplicationController
  before_action :authenticate_user!

  def index
    authorize :operations_dashboard, :index?

    business = current_user.business
    @today   = BusinessDay.current(context: business)
    @from    = @today.beginning_of_month

    # ── Today attendance ─────────────────────────────────────────────────────
    employee_ids = scoped_employee_ids(business)
    today_records = AttendanceRecord
      .active
      .where(user_id: employee_ids, date: @today)
      .includes(user: { profile_photo_attachment: :blob })
      .to_a

    @total_employees   = employee_ids.size
    @checked_in_count  = today_records.count { |r| r.check_in_at.present? }
    @checked_out_count = today_records.count { |r| r.checked_out? }
    @active_now_count  = @checked_in_count - @checked_out_count

    # ── Late employees today ──────────────────────────────────────────────────
    @late_today = today_records.select { |r| r.late? || r.late_minutes.to_i > 0 }
                               .sort_by { |r| -r.late_minutes.to_i }
                               .first(10)

    # ── Missing checkouts (yesterday) ────────────────────────────────────────
    @missing_checkouts = AttendanceRecord
      .active
      .where(user_id: employee_ids, date: @today - 1, status: "incomplete")
      .includes(user: { profile_photo_attachment: :blob })
      .order(check_in_at: :asc)

    # ── Branch health grid ────────────────────────────────────────────────────
    @branch_health = build_branch_health(business, employee_ids, @today)

    # ── Payroll alerts ────────────────────────────────────────────────────────
    @pending_periods = PayrollPeriod
      .where(business: business)
      .where(status: %w[draft under_review branch_review_completed])
      .order(period_year: :asc, period_month: :asc)

    # ── Pending approvals ─────────────────────────────────────────────────────
    @pending_adjustments_count = PayrollAdjustment
      .pending
      .joins(:payroll_period)
      .where(payroll_periods: { business_id: business.id })
      .count

    @pending_line_items_count = PayrollLineItem
      .pending_review
      .joins(payroll_entry: :payroll_period)
      .where(payroll_periods: { business_id: business.id })
      .count

    # ── Shared monthly records — loaded once for anomaly + performance ───────
    monthly_records_by_user = AttendanceRecord
      .active
      .where(user_id: employee_ids, work_date: @from..@today)
      .order(:work_date)
      .to_a
      .group_by(&:user_id)

    # ── Attendance anomalies (monthly window) ─────────────────────────────────
    @anomaly_users = build_anomaly_summary(business, employee_ids, monthly_records_by_user)

    # ── Performance: top + at-risk employees ─────────────────────────────────
    @perf_results = build_performance_summary(business, employee_ids, monthly_records_by_user)

    # ── Recommendations ───────────────────────────────────────────────────────
    # Payroll-derived recommendations only from the payroll the viewer may see
    # (view_payroll and its scope); none without view_payroll.
    payroll_entries = current_user.can?(:view_payroll) ? policy_scope(PayrollEntry) : PayrollEntry.none
    @recommendations = Payroll::RecommendationEngine.new(
      business: business, payroll_entries: payroll_entries,
      payroll_branch_ids: PayrollEntryPolicy.visible_branch_ids(current_user)
    ).recommendations
  end

  private

  def scoped_employee_ids(business)
    if current_user.can?(:view_payroll)
      business.users.where(active: true).pluck(:id)
    else
      EmployeeScope.new(current_user).relation.where(active: true).pluck(:id)
    end
  end

  def build_branch_health(business, employee_ids, today)
    from       = today.beginning_of_month
    branches   = business.branches.active.order(:name)
    branch_ids = branches.map(&:id)

    # Batch-load all monthly records for all employees at once. Attendance carries
    # its own branch_id (where the work happened), so group on it directly.
    month_counts = AttendanceRecord
      .active
      .where(user_id: employee_ids, work_date: from..today, branch_id: branch_ids)
      .group(:branch_id, :status)
      .count  # { [branch_id, status] => count }

    today_checked_in = AttendanceRecord
      .active
      .where(user_id: employee_ids, date: today, branch_id: branch_ids)
      .where.not(check_in_at: nil)
      .group(:branch_id)
      .count  # { branch_id => count }

    # branch_id → [user_ids] currently assigned (shift-driven membership),
    # limited to the visible employee set.
    members_by_branch = ShiftAssignment
      .active_on(today)
      .where(branch_id: branch_ids, user_id: employee_ids)
      .joins(:user).where(users: { active: true })
      .distinct.pluck(:branch_id, :user_id)
      .each_with_object(Hash.new { |h, k| h[k] = [] }) { |(bid, uid), h| h[bid] << uid }

    branches.map do |branch|
      branch_emp_ids = members_by_branch[branch.id] || []
      next if branch_emp_ids.empty?

      late_month   = month_counts[[branch.id, "late"]].to_i
      absent_month = month_counts[[branch.id, "absent"]].to_i
      checked_in_today = today_checked_in[branch.id].to_i

      late_pct     = (late_month.to_f / [ branch_emp_ids.size, 1 ].max * 100).round
      health_score = [ 100 - late_pct * 2, 0 ].max

      {
        branch:           branch,
        employee_count:   branch_emp_ids.size,
        checked_in_today: checked_in_today,
        late_month:       late_month,
        absent_month:     absent_month,
        health_score:     health_score
      }
    end.compact
  end

  def build_anomaly_summary(business, employee_ids, records_by_user)
    from  = @from
    to    = @today
    users = business.users.where(id: employee_ids, active: true)
                    .includes(profile_photo_attachment: :blob)

    anomalies_by_user = {}
    users.each do |u|
      found = Attendance::AnomalyDetector.new(
        user:    u,
        from:    from,
        to:      to,
        records: records_by_user[u.id] || []
      ).detect
      anomalies_by_user[u] = found unless found.empty?
    end

    anomalies_by_user
      .sort_by { |_, anoms| -anoms.count }
      .first(8)
      .map { |user, anoms|
        {
          user:             user,
          anomaly_count:    anoms.count,
          highest_severity: anoms.min_by { |a| severity_rank(a.severity) }&.severity,
          codes:            anoms.map(&:code).uniq
        }
      }
  end

  def build_performance_summary(business, employee_ids, records_by_user)
    from  = @from
    to    = @today
    users = business.users.where(id: employee_ids, active: true)
                    .includes(profile_photo_attachment: :blob)

    scored = users.map { |u|
      result = Employee::PerformanceScorer.call(
        user:    u,
        from:    from,
        to:      to,
        records: records_by_user[u.id] || []
      )
      next if result.total_days < 3
      { user: u, score: result.score, grade: result.grade }
    }.compact

    {
      top:     scored.sort_by { |r| -r[:score] }.first(5),
      at_risk: scored.select  { |r| r[:score] < 55 }.sort_by { |r| r[:score] }.first(5)
    }
  end

  def severity_rank(sev)
    { danger: 0, warning: 1, info: 2 }.fetch(sev.to_sym, 3)
  end
end
