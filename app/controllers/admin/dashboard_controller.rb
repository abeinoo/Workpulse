class Admin::DashboardController < Admin::BaseController
  # The admin gate admits branch-scopable permissions (view_employees,
  # view_payroll, …), so staff, requests and payroll periods are read through
  # the same policy scopes as their own index pages (A1 / BUG-020).
  def index
    business  = current_user.business
    employees = policy_scope(User)
    @stats = {
      employees:        employees.where.not(id: business.owner_id).count,
      branches:         business.branches.active.count,
      pending_requests: policy_scope(EmployeeRequest).pending.count,
      active_shifts:    Shift.where(business_id: business.id, active: true).count
    }
    @recent_payroll_periods = policy_scope(PayrollPeriod)
                                .where(branch: business.branches)
                                .order(period_year: :desc, period_month: :desc)
                                .includes(:branch)
                                .limit(5)
    @recent_employees = employees.includes(:permission_role).order(created_at: :desc).limit(5)
  end
end
