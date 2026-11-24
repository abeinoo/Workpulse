# Stock Issue workflow settings — owner-only (no delegation approved). The
# change itself is made by the audited OrganizationAccess::StockIssueWorkflowSettings,
# which re-checks the owner and writes a fail-closed audit entry.
class Inventory::StockIssueWorkflowSettingsController < Inventory::BaseController
  before_action :require_owner!

  def show
    @business = current_user.business
  end

  def update
    result = OrganizationAccess::StockIssueWorkflowSettings.call(
      business: current_user.business, actor: current_user,
      self_approval: settings_params[:self_approval], quick_issue_enabled: settings_params[:quick_issue_enabled]
    )
    if result.ok? || result.error == :unchanged
      redirect_to inventory_stock_issue_workflow_settings_path, notice: t("inventory.stock_issue_workflow_settings.saved")
    else
      @business = current_user.business.reload
      flash.now[:alert] = t("inventory.stock_issue_workflow_settings.failed")
      render :show, status: :unprocessable_entity
    end
  end

  private

  def require_owner!
    raise Pundit::NotAuthorizedError unless OrganizationAccess::StockIssueWorkflowSettings.permitted?(current_user, current_user.business)
  end

  def settings_params
    params.require(:stock_issue_workflow_settings).permit(:self_approval, :quick_issue_enabled)
  end
end
