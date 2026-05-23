class Admin::DashboardController < Admin::BaseController
  def index
    business = current_user.business
    @stats = {
      employees:        business.users.where.not(id: business.owner_id).count,
      branches:         business.branches.active.count,
      pending_requests: EmployeeRequest.for_business(business).pending.count,
      active_shifts:    Shift.where(business_id: business.id, active: true).count
    }
    @recent_payroll_periods = PayrollPeriod.where(branch: business.branches)
                                           .order(period_year: :desc, period_month: :desc)
                                           .includes(:branch)
                                           .limit(5)
    @recent_employees = business.users.includes(:permission_role).order(created_at: :desc).limit(5)
  end
end
