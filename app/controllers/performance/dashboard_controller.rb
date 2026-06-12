class Performance::DashboardController < Performance::BaseController
  before_action :require_reporting_access!

  def index
    @year      = (params[:year].presence || Date.current.year).to_i
    @analytics = Performance::Analytics.new(current_user.business, year: @year)

    @top_employees      = @analytics.top_employees(5)
    @lowest_employees   = @analytics.lowest_employees(5)
    @department_ranking = @analytics.department_rankings
    @weak_areas         = @analytics.weak_areas(5)

    @recent_reviews = policy_scope(PerformanceReview)
                        .includes(:employee, :department)
                        .recent_first.limit(8)
  end

  private

  def require_reporting_access!
    return if current_user.can?(:view_performance) || current_user.can?(:manage_reviews)

    redirect_to root_path, alert: t("flash.not_authorized")
  end
end
