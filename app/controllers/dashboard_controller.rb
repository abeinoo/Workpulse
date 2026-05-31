class DashboardController < ApplicationController
  before_action :authenticate_user!

  # The dashboard is composed of independent sections. Each section decides
  # for itself whether it renders, based on permissions (visibility) and the
  # user's relationships (data scope). A user with multiple responsibilities
  # sees every section they qualify for — sections are additive, never
  # mutually-exclusive. Personal/self-owned widgets are universal.
  def index
    load_personal_data
    load_branch_management_data if show_branch_management_section?
    load_area_management_data   if show_area_management_section?
    load_payroll_data           if show_payroll_section?
    load_analytics_data         if show_analytics_section?
  end

  private

  # ── Section visibility gates ──────────────────────────────────────────────
  # Visibility is permission-driven. Relationships only determine data scope
  # (and an empty scope naturally yields a section with nothing to show, so we
  # additionally require the scope to be non-empty before rendering).

  helper_method :show_branch_management_section?,
                :show_area_management_section?,
                :show_payroll_section?,
                :show_analytics_section?

  def show_branch_management_section?
    return @show_branch_management_section if defined?(@show_branch_management_section)

    @show_branch_management_section =
      current_user.can?(:view_attendance) && branch_management_scope_present?
  end

  def show_area_management_section?
    return @show_area_management_section if defined?(@show_area_management_section)

    @show_area_management_section =
      current_user.can?(:view_attendance) && current_user.area_managed_branch_ids.any?
  end

  def show_payroll_section?
    current_user.can?(:view_payroll)
  end

  # Business-wide operational analytics: the owner, or any role explicitly
  # granted business-wide attendance visibility.
  def show_analytics_section?
    current_user.owner? ||
      (current_user.can?(:view_attendance) &&
        current_user.scope_for(:view_attendance) == "business_wide")
  end

  # A user has a branch-management scope when they are the assigned manager of
  # a branch, or have direct reports. Cheap existence checks — only evaluated
  # for users who already cleared the :view_attendance permission gate.
  def branch_management_scope_present?
    Branch.where(branch_manager_id: current_user.id).exists? ||
      current_user.managed_employees.where(active: true).exists?
  end

  # ── Personal section (universal) ──────────────────────────────────────────
  # Self-owned widgets shown to every user regardless of role: attendance,
  # schedule (assignment-driven), month stats, personal requests/payroll.
  def load_personal_data
    today = BusinessDay.current(context: current_user.business)

    @today_record    = AttendanceRecord.find_by(user: current_user, date: today)
    @current_shift   = ShiftAssignment.current
                                      .includes(:shift, :branch, :source_template)
                                      .find_by(user: current_user)

    # Attendance eligibility is shift-driven. Branch context comes exclusively from
    # active ShiftAssignments — no fallback to permanent user_branches.
    # When mobile attendance is disabled the check-in widget is suppressed entirely;
    # the employee's status card (if already checked in via biometric) still shows.
    @today_branches =
      if current_user.allow_mobile_attendance?
        ShiftAssignment.current
                       .where(user: current_user)
                       .includes(:branch)
                       .filter_map(&:branch)
                       .uniq
      else
        []
      end

    # Warn if the user left an open check-in from yesterday.
    @missing_checkout = AttendanceRecord.find_by(
      user: current_user, date: today - 1, status: "incomplete"
    )

    # Next 3 future shift assignments (excludes today/ongoing).
    @upcoming_shifts = ShiftAssignment
      .where(user: current_user)
      .where("effective_from > ?", Date.current)
      .order(:effective_from)
      .includes(:shift, :branch, :source_template)
      .limit(3)

    # Month-to-date attendance counts (anchored on the current business day).
    month_records = AttendanceRecord.where(
      user: current_user,
      date: today.beginning_of_month..today
    )
    @month_stats = {
      days_present:  month_records.where(status: %w[present late early_leave]).count,
      late_arrivals: month_records.where(status: "late").count,
      absences:      month_records.where(status: "absent").count,
    }

    # Whether the user participates in attendance at all. Drives the month-stats
    # widget so users with no shifts and no history (e.g. owners) don't see an
    # all-zero card. Cheap: reuses already-loaded values plus one EXISTS.
    @month_attendance_count = @month_stats.values.sum
    @has_attendance_context =
      @today_record.present? || @today_branches.any? ||
      @current_shift.present? || @upcoming_shifts.any? ||
      @month_attendance_count.positive?

    @recent_requests = current_user.employee_requests
                                   .order(created_at: :desc)
                                   .limit(3)

    # Only show payroll from finalized/paid periods — never show draft payroll.
    @latest_payroll = current_user.payroll_entries
                                  .employee_visible
                                  .joins(:payroll_period)
                                  .order("payroll_periods.period_year DESC, payroll_periods.period_month DESC")
                                  .first

    # Recent unread notifications for alert feed.
    @recent_notifications = current_user.notifications.unread.recent.limit(5)

    # Whether any personal widget will render — lets the view skip the personal
    # grid wrapper entirely (and its surrounding gap) for users with nothing
    # personal to show, e.g. owners. Derived from already-loaded values.
    @has_personal_widgets =
      @missing_checkout.present? || @has_attendance_context ||
      @recent_requests.any? || @recent_notifications.any? ||
      @latest_payroll.present?
  end

  # ── Branch management section ─────────────────────────────────────────────
  def load_branch_management_data
    # Branch managers are officially assigned to branches via Branch#branch_manager_id.
    # user_branches is supplementary (many-to-many). Both sources must be combined.
    direct_branch_ids = Branch.where(branch_manager_id: current_user.id).pluck(:id)
    all_branch_ids    = (direct_branch_ids + current_user.branch_ids).uniq
    @managed_branches = Branch.where(id: all_branch_ids).active.order(:name)

    today     = BusinessDay.current(context: current_user.business)
    yesterday = today - 1

    # Full team: all active employees directly managed by this manager
    @managed_employees = current_user.managed_employees
                                     .where(active: true)
                                     .includes(profile_photo_attachment: :blob)
                                     .order(:first_name, :last_name)

    managed_ids = @managed_employees.map(&:id)

    # Keyed hash for O(1) lookup in the view: user_id → today's record
    @managed_today_records = AttendanceRecord
      .where(user_id: managed_ids, date: today)
      .index_by(&:user_id)

    @branch_employee_count = managed_ids.size
    @checked_in_count = @managed_today_records.count { |_, r| r.check_in_at.present? }

    # Employees with an open check-in from yesterday (forgot to check out)
    @missing_checkouts = AttendanceRecord
      .where(user_id: managed_ids, date: yesterday, status: "incomplete")
      .includes(:user)

    scope_ids = EmployeeScope.new(current_user).relation.select(:id)
    @pending_requests = EmployeeRequest
      .pending
      .where(user_id: scope_ids)
      .includes(:user)
      .order(created_at: :asc)

    @pending_adjustments = PayrollAdjustment
      .pending
      .where(user_id: managed_ids)
      .includes(:user, :created_by)
      .order(created_at: :desc)
      .limit(10)
  end

  # ── Area management section ───────────────────────────────────────────────
  def load_area_management_data
    data = Dashboard::AreaManagerData.call(current_user)

    @area_branches      = data.managed_branches
    @branch_health      = data.branch_health
    @critical_alerts    = data.critical_alerts
    @branch_ranking     = data.branch_ranking
    @pending_approvals  = data.pending_approvals
    @workforce_coverage = data.workforce_coverage
    @attendance_trend   = data.attendance_trend
    @area_stats         = data.stats
  end

  # ── Payroll section ───────────────────────────────────────────────────────
  def load_payroll_data
    @draft_periods = policy_scope(PayrollPeriod)
      .where(status: :draft)
      .includes(:branch)
      .order(period_year: :desc, period_month: :desc)
      .limit(5)
    @approved_periods = policy_scope(PayrollPeriod)
      .where(status: :finalized)
      .includes(:branch)
      .order(period_year: :desc, period_month: :desc)
      .limit(5)
  end

  # ── Business analytics section ────────────────────────────────────────────
  def load_analytics_data
    data = Dashboard::OwnerData.call(current_user.business)

    @stats                    = data.stats
    @trends                   = data.trends
    @active_now               = data.active_now
    @branch_snapshots         = data.branch_snapshots
    @recent_payroll_periods   = data.recent_payroll_periods
    @business_missing_checkouts = data.missing_checkouts
  end
end
