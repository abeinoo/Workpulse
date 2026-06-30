class Performance::ReportsController < Performance::BaseController
  before_action :require_reports_access!
  before_action :set_analytics

  def index
    @top_employees      = @analytics.top_employees(10)
    @lowest_employees   = @analytics.lowest_employees(10)
    @department_ranking = @analytics.department_rankings
    @weak_areas         = @analytics.weak_areas(10)
    @business_trend     = @analytics.monthly_trend
  end

  # Per-employee score history (the monthly trend report).
  def trend
    @employee = policy_scope(PerformanceReview)
                  .where(employee_id: params[:employee_id]).first&.employee
    @employee ||= current_user.business.users.find_by(id: params[:employee_id])

    @trend = @employee ? @analytics.monthly_trend(employee: @employee) : []
    @employees = selectable_employees
  end

  private

  def set_analytics
    @year      = (params[:year].presence || Date.current.year).to_i
    @analytics = Performance::Analytics.new(current_user.business, year: @year)
  end

  def require_reports_access!
    return if current_user.can?(:view_performance_reports)

    redirect_to root_path, alert: t("flash.not_authorized")
  end
end
