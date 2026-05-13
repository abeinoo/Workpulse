class DashboardController < ApplicationController
  before_action :authenticate_user!

  def index
    if current_user.super_admin?
      load_super_admin_data
    elsif current_user.area_manager?
      load_area_manager_data
    elsif current_user.branch_manager?
      load_branch_manager_data
    elsif current_user.accountant?
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
    branch_ids        = current_user.branch_ids
    @managed_branches = current_user.branches.active.order(:name)

    # Manager's own attendance (they are also an employee)
    @my_today_record  = AttendanceRecord.find_by(user: current_user, date: Date.current)
    @my_current_shift = ShiftAssignment.current.find_by(user: current_user)

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

    @pending_requests = EmployeeRequest
      .where(user_id: managed_ids, status: "pending")
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
    business = current_user.business
    @draft_periods = PayrollPeriod
      .where(business: business, status: :draft)
      .includes(:branch)
      .order(period_year: :desc, period_month: :desc)
      .limit(5)
    @approved_periods = PayrollPeriod
      .where(business: business, status: :finalized)
      .includes(:branch)
      .order(period_year: :desc, period_month: :desc)
      .limit(5)
    @recent_periods = PayrollPeriod
      .where(business: business)
      .includes(:branch)
      .order(period_year: :desc, period_month: :desc)
      .limit(8)
  end

  def load_employee_data
    @today_record    = AttendanceRecord.find_by(user: current_user, date: Date.current)
    @current_shift   = ShiftAssignment.current.find_by(user: current_user)
    @recent_requests = current_user.employee_requests
                                   .order(created_at: :desc)
                                   .limit(3)
    @latest_payroll  = current_user.payroll_entries
                                   .joins(:payroll_period)
                                   .order("payroll_periods.period_year DESC, payroll_periods.period_month DESC")
                                   .first
  end
end
