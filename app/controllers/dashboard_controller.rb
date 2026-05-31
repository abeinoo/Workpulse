class DashboardController < ApplicationController
  before_action :authenticate_user!

  def index
    if current_user.owner?
      load_super_admin_data
    elsif current_user.manages_area?
      load_area_manager_data
    elsif current_user.manages_branch?
      load_branch_manager_data
    elsif current_user.can?(:view_payroll)
      load_accountant_data
    else
      load_employee_data
    end
  end

  private

  def load_super_admin_data
    data = Dashboard::OwnerData.call(current_user.business)

    @stats                  = data.stats
    @trends                 = data.trends
    @active_now             = data.active_now
    @branch_snapshots       = data.branch_snapshots
    @today_records_by_user  = data.today_records_by_user
    @recent_payroll_periods = data.recent_payroll_periods
    @missing_checkouts      = data.missing_checkouts
  end

  def load_area_manager_data
    data = Dashboard::AreaManagerData.call(current_user)

    @managed_branches   = data.managed_branches
    @branch_health      = data.branch_health
    @critical_alerts    = data.critical_alerts
    @branch_ranking     = data.branch_ranking
    @pending_approvals  = data.pending_approvals
    @workforce_coverage = data.workforce_coverage
    @attendance_trend   = data.attendance_trend
    @area_stats         = data.stats
  end

  def load_branch_manager_data
    # Branch managers are officially assigned to branches via Branch#branch_manager_id.
    # user_branches is supplementary (many-to-many). Both sources must be combined.
    direct_branch_ids = Branch.where(branch_manager_id: current_user.id).pluck(:id)
    all_branch_ids    = (direct_branch_ids + current_user.branch_ids).uniq
    @managed_branches = Branch.where(id: all_branch_ids).active.order(:name)
    branch_ids        = @managed_branches.pluck(:id)

    # Business day boundaries respect the configured start hour (see BusinessDay).
    today     = BusinessDay.current(context: current_user.business)
    yesterday = today - 1

    # Manager's own attendance (they are also an employee)
    @my_today_record  = AttendanceRecord.find_by(user: current_user, date: today)
    @my_current_shift = ShiftAssignment.current.find_by(user: current_user)

    # Attendance eligibility for the manager themselves is shift-driven.
    # Branch context comes exclusively from their active ShiftAssignment.
    # No fallback to permanent branch relations.
    # When mobile attendance is disabled, suppress check-in/check-out controls.
    @my_check_in_branches =
      if current_user.allow_mobile_attendance?
        ShiftAssignment.current
                       .where(user: current_user)
                       .includes(:branch)
                       .filter_map(&:branch)
                       .uniq
      else
        []
      end

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

    @today_records = AttendanceRecord
      .where(branch_id: branch_ids, date: today)
      .includes(:user)
      .order("users.first_name")

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

  def load_accountant_data
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
    @recent_periods = policy_scope(PayrollPeriod)
      .includes(:branch)
      .order(period_year: :desc, period_month: :desc)
      .limit(8)
  end

  def load_employee_data
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

    # Warn if the employee left an open check-in from yesterday.
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
  end
end
