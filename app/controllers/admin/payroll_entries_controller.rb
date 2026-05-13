class Admin::PayrollEntriesController < Admin::BaseController
  def index
    @period  = find_period
    authorize @period, :show?
    @entries = @period.payroll_entries.includes(:user).order("users.first_name, users.last_name")
  end

  def show
    @period = find_period
    @entry  = @period.payroll_entries.find(params[:id])
    authorize @entry
  end

  def update
    @period = find_period
    @entry  = @period.payroll_entries.find(params[:id])
    authorize @entry
    if @entry.update(entry_params)
      redirect_to admin_payroll_period_payroll_entry_path(@period, @entry), notice: "Entry updated."
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

  def find_period
    policy_scope(PayrollPeriod).find(params[:payroll_period_id])
  end

  def entry_params
    params.require(:payroll_entry).permit(:notes, :adjustments)
  end

  def require_super_admin!
    redirect_to root_path, alert: "Not authorized." unless current_user.super_admin? || current_user.accountant?
  end
end
