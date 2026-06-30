class Performance::BaseController < ApplicationController
  before_action :authenticate_user!
  before_action :require_performance_access!

  private

  # Any of the four view permissions or any write permission grants entry to the
  # module. Per-action authorization is enforced by Pundit in each controller.
  def require_performance_access!
    return if current_user.can?(:view_performance_dashboard) ||
              current_user.can?(:view_notes)                 ||
              current_user.can?(:view_monthly_reviews)       ||
              current_user.can?(:view_performance_reports)   ||
              current_user.can?(:create_observations)        ||
              current_user.can?(:manage_reviews)             ||
              current_user.can?(:finalize_reviews)           ||
              current_user.can?(:manage_evaluation_templates)

    redirect_to root_path, alert: t("flash.not_authorized")
  end

  # Active employees the current user may act on, for observation/review pickers.
  # Owners and business-scoped users see everyone; otherwise the managed set.
  def selectable_employees
    base = current_user.business.users.active
    configured = current_user.scope_for(:create_observations) ||
                 current_user.scope_for(:view_notes)          ||
                 current_user.scope_for(:view_performance_dashboard)

    if current_user.owner? || configured == "business"
      base.order(:first_name, :last_name)
    else
      ids = EmployeeScope.new(current_user).relation.select(:id)
      base.where(id: ids).or(base.where(id: current_user.id))
          .order(:first_name, :last_name)
    end
  end
  helper_method :selectable_employees
end
