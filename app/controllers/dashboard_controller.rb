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
    business = current_user.business
    @stats = {
      employees:        business.users.count,
      branches:         business.branches.active.count,
      pending_requests: EmployeeRequest.for_business(business).pending.count
    }
    @recent_payroll_periods = PayrollPeriod
      .where(business: business)
      .order(period_year: :desc, period_month: :desc)
      .limit(4)
  end

  def load_area_manager_data
    @managed_branches = Branch.where(area_manager: current_user).includes(:branch_manager).order(:name)
    branch_ids        = @managed_branches.pluck(:id)

    employee_ids = User.joins(:user_branches)
                       .where(user_branches: { branch_id: branch_ids })
                       .where(active: true)
                       .pluck(:id)

    @checked_in_today = AttendanceRecord
      .where(user_id: employee_ids, date: Date.current)
      .count

    @employee_count = employee_ids.size

    @pending_adjustments = PayrollAdjustment
      .pending
      .where(user_id: employee_ids)
      .includes(:user, :created_by)
      .order(created_at: :desc)
      .limit(15)

    @branch_summaries = @managed_branches.map do |branch|
      branch_emp_ids = User.joins(:user_branches)
                           .where(user_branches: { branch_id: branch.id })
                           .where(active: true)
                           .pluck(:id)
      checked_in = AttendanceRecord.where(user_id: branch_emp_ids, date: Date.current).count
      late_count  = AttendanceRecord.where(user_id: branch_emp_ids, date: Date.current, status: "late").count
      {
        branch:        branch,
        employee_count: branch_emp_ids.size,
        checked_in:    checked_in,
        late:          late_count
      }
    end
  end

  def load_branch_manager_data
    # Branch managers are officially assigned to branches via Branch#branch_manager_id.
    # user_branches is supplementary (many-to-many). Both sources must be combined.
    direct_branch_ids = Branch.where(branch_manager_id: current_user.id).pluck(:id)
    all_branch_ids    = (direct_branch_ids + current_user.branch_ids).uniq
    @managed_branches = Branch.where(id: all_branch_ids).active.order(:name)
    branch_ids        = @managed_branches.pluck(:id)

    # Manager's own attendance (they are also an employee)
    @my_today_record  = AttendanceRecord.find_by(user: current_user, date: Date.current)
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
                                     .order(:first_name, :last_name)

    managed_ids = @managed_employees.map(&:id)

    # Keyed hash for O(1) lookup in the view: user_id → today's record
    @managed_today_records = AttendanceRecord
      .where(user_id: managed_ids, date: Date.current)
      .index_by(&:user_id)

    @branch_employee_count = managed_ids.size

    @today_records = AttendanceRecord
      .where(branch_id: branch_ids, date: Date.current)
      .includes(:user)
      .order("users.first_name")

    @checked_in_count = @managed_today_records.count { |_, r| r.check_in_at.present? }

    # Employees with an open check-in from yesterday (forgot to check out)
    @missing_checkouts = AttendanceRecord
      .where(user_id: managed_ids, date: Date.yesterday, status: "incomplete")
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
    @today_record    = AttendanceRecord.find_by(user: current_user, date: Date.current)
    @current_shift   = ShiftAssignment.current.find_by(user: current_user)

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

    @recent_requests = current_user.employee_requests
                                   .order(created_at: :desc)
                                   .limit(3)
    @latest_payroll  = current_user.payroll_entries
                                   .joins(:payroll_period)
                                   .order("payroll_periods.period_year DESC, payroll_periods.period_month DESC")
                                   .first
  end
end
