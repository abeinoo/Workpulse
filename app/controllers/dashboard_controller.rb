class DashboardController < ApplicationController
  before_action :authenticate_user!

  # The dashboard is composed of independent sections. Each section decides
  # for itself whether it renders, based on permissions (visibility) and the
  # user's relationships (data scope). A user with multiple responsibilities
  # sees every section they qualify for — sections are additive, never
  # mutually-exclusive. Personal/self-owned widgets are universal.
  def index
    load_personal_data
    load_birthday_data
    load_branch_management_data if show_branch_management_section?
    load_area_management_data   if show_area_management_section?
    load_payroll_data           if show_payroll_section?
    load_analytics_data         if show_analytics_section?
    load_inventory_data         if show_inventory_section?
  end

  private

  # ── Section visibility gates ──────────────────────────────────────────────
  # Visibility is PERMISSION-DRIVEN. A user sees the UNION of every section they
  # have access to; no gate depends on another section, and no gate is keyed to
  # a specific role/relationship FK (which previously hid sections from
  # admins/owners who hold the permission but aren't assigned as a branch/area
  # manager). Relationships and the user's configured permission scope only
  # decide *which data* a section shows — for business-wide users that is the
  # whole business. Empty data still collapses a section.

  helper_method :show_branch_management_section?,
                :show_area_management_section?,
                :show_payroll_section?,
                :show_analytics_section?,
                :show_inventory_section?,
                :show_team_birthdays?

  # Inventory low-stock summary: anyone who can view inventory. Warehouse-scoped
  # users only see alerts for their assigned warehouses.
  def show_inventory_section?
    return @show_inventory_section if defined?(@show_inventory_section)

    @show_inventory_section =
      current_user.can?(:view_inventory) || current_user.can?(:manage_inventory)
  end

  def load_inventory_data
    @inventory_low_stock = Inventory::LowStockQuery.new(
      current_user.business, warehouse_ids: current_user.inventory_warehouse_ids
    ).alerts.first(8)
  end

  # Team / branch management (roster, pending requests/adjustments): anyone who
  # manages at least one branch or can see other employees via the business-wide
  # attendance scope. Employee-only users (no management role, self/branch-only
  # scope) get neither condition and see nothing here.
  def show_branch_management_section?
    return @show_branch_management_section if defined?(@show_branch_management_section)

    @show_branch_management_section =
      current_user.can?(:view_attendance) &&
      (accessible_branch_ids.any? || attendance_employee_scope.exists?)
  end

  # Branch oversight analytics (branch health, ranking, coverage, trend, critical
  # alerts): anyone who can view attendance for one or more branches in scope.
  def show_area_management_section?
    return @show_area_management_section if defined?(@show_area_management_section)

    @show_area_management_section =
      current_user.can?(:view_attendance) && accessible_branch_ids.any?
  end

  def show_payroll_section?
    current_user.can?(:view_payroll)
  end

  # Business-wide operational analytics — requires view_dashboard in addition
  # to business-wide attendance access. This is the management analytics tier
  # (KPIs, branch rankings, trends) that view_dashboard specifically gates.
  def show_analytics_section?
    current_user.can?(:view_dashboard) && business_wide_attendance?
  end

  # ── Scope helpers (data scope — never visibility) ─────────────────────────

  # True when the user can see attendance for the whole business: the owner, or
  # a permission role whose view_attendance scope is explicitly business_wide.
  def business_wide_attendance?
    return @business_wide_attendance if defined?(@business_wide_attendance)

    @business_wide_attendance =
      current_user.owner? ||
      (current_user.can?(:view_attendance) &&
        current_user.scope_for(:view_attendance) == "business")
  end

  # Employees this user may view — honours an explicit view_attendance scope
  # (business_wide for owners/admins) and otherwise falls back to the
  # relationship hierarchy (managed branches / area branches / direct reports).
  def attendance_employee_scope
    @attendance_employee_scope ||=
      if business_wide_attendance?
        EmployeeScope.new(current_user).for_scope("business")
      else
        EmployeeScope.new(current_user).relation
      end
  end

  # Branches this user oversees: every active branch for business-wide users,
  # otherwise the branches they are assigned as branch_manager_id or area_manager_id.
  # Employee branch membership (ShiftAssignment) is intentionally excluded — being
  # assigned to a branch as an employee does not confer management visibility.
  def accessible_branch_ids
    @accessible_branch_ids ||=
      if business_wide_attendance?
        Branch.for_business(current_user.business).active.pluck(:id)
      else
        (current_user.managed_branch_ids + current_user.area_managed_branch_ids).uniq
      end
  end

  # ── Personal section (universal) ──────────────────────────────────────────
  # Self-owned widgets shown to every user regardless of role: attendance,
  # schedule (assignment-driven), month stats, personal requests/payroll.
  def load_personal_data
    today = BusinessDay.current(context: current_user.business)

    @today_record    = AttendanceRecord.active.find_by(user: current_user, date: today)
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
    @missing_checkout = AttendanceRecord.active.find_by(
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
    month_records = AttendanceRecord.active.where(
      user: current_user,
      date: today.beginning_of_month..today
    )
    @month_stats = {
      days_present:  month_records.where(status: AttendanceRecord::ATTENDED_STATUSES).count,
      late_arrivals: month_records.where(status: AttendanceRecord::LATE_STATUSES).count,
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
    Payroll::EntryViewAudit.record(actor: current_user, entries: [ @latest_payroll ], source: "dashboard_latest_payslip")

    # Whether any personal widget will render — lets the view skip the personal
    # grid wrapper entirely (and its surrounding gap) for users with nothing
    # personal to show, e.g. owners. Derived from already-loaded values.
    @has_personal_widgets =
      @missing_checkout.present? || @has_attendance_context ||
      @recent_requests.any? || @latest_payroll.present?
  end

  # ── Birthdays ─────────────────────────────────────────────────────────────
  # The viewer's own celebration (once per business day) plus today's team
  # birthdays for anyone who can view employees. The team list is drawn from
  # policy_scope(User), so it never reveals employees the viewer can't access.
  def show_team_birthdays?
    current_user.can?(:view_employees)
  end

  def load_birthday_data
    today = BusinessDay.current(context: current_user.business)

    @birthday_today = current_user.birthday_on?(today)
    @show_birthday_celebration =
      @birthday_today &&
      !Dashboard::Birthdays::Celebration.shown?(current_user, today)

    @team_birthdays =
      show_team_birthdays? ? Dashboard::Birthdays.team(policy_scope(User), viewer: current_user, date: today) : []
  end

  # ── Branch management section ─────────────────────────────────────────────
  def load_branch_management_data
    # Branches and employees both come from the permission-aware scope helpers,
    # so a business-wide permission holder (owner/admin) sees the whole business
    # even without a branch_manager/area_manager relationship.
    @managed_branches = Branch.where(id: accessible_branch_ids).active.order(:name)

    today     = BusinessDay.current(context: current_user.business)
    yesterday = today - 1

    # Team: every active employee the user can view (scope-driven, not FK-driven)
    @managed_employees = attendance_employee_scope
                           .where(active: true)
                           .includes(profile_photo_attachment: :blob)
                           .order(:first_name, :last_name)

    managed_ids = @managed_employees.map(&:id)

    # Keyed hash for O(1) lookup in the view: user_id → today's record
    @managed_today_records = AttendanceRecord
      .active
      .where(user_id: managed_ids, date: today)
      .index_by(&:user_id)

    @branch_employee_count = managed_ids.size
    @checked_in_count = @managed_today_records.count { |_, r| r.check_in_at.present? }

    # Employees with an open check-in from yesterday (forgot to check out)
    @missing_checkouts = AttendanceRecord
      .active
      .where(user_id: managed_ids, date: yesterday, status: "incomplete")
      .includes(:user)

    @pending_requests = EmployeeRequest
      .pending
      .where(user_id: attendance_employee_scope.select(:id))
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
    # Scope the oversight analytics to the branches this user can reach
    # (all branches for business-wide users) rather than only area-managed ones.
    data = Dashboard::AreaManagerData.call(current_user, branch_scope: accessible_branch_ids)

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
