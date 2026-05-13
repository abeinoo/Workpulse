class Admin::PayrollPeriodsController < Admin::BaseController
  def index
    authorize PayrollPeriod
    @periods = policy_scope(PayrollPeriod)
                 .includes(:branch)
                 .order(period_year: :desc, period_month: :desc)
  end

  def show
    @period  = find_period
    authorize @period
    @entries = @period.payroll_entries.includes(:user).order("users.first_name, users.last_name")
    @branch_reviews = @period.payroll_period_branch_reviews.includes(:branch, :reviewer)
    @audit_logs     = @period.payroll_audit_logs.includes(:actor).order(created_at: :asc)
  end

  # Super admin finalizes a period (branch_review_completed or under_review override).
  def finalize
    period = find_period
    authorize period, :finalize?

    result = Payroll::Approver.advance(period: period, by: current_user)
    if result.success?
      redirect_to admin_payroll_period_path(period), notice: t("flash.period_finalized")
    else
      redirect_to admin_payroll_period_path(period), alert: result.error
    end
  end

  def mark_paid
    period = find_period
    authorize period, :mark_paid?

    result = Payroll::Approver.advance(period: period, by: current_user)
    if result.success?
      redirect_to admin_payroll_period_path(period), notice: t("flash.period_paid")
    else
      redirect_to admin_payroll_period_path(period), alert: result.error
    end
  end

  # Regenerate a draft period from attendance records.
  def regenerate
    period = find_period
    authorize period, :regenerate?

    result = Payroll::Regenerator.call(period: period, regenerated_by: current_user)
    if result.success?
      redirect_to admin_payroll_period_path(result.period), notice: t("flash.payroll_regenerated")
    else
      redirect_to admin_payroll_period_path(period), alert: result.error
    end
  end

  # Delete a draft period entirely (super admin only).
  def destroy
    period = find_period
    authorize period, :destroy?

    PayrollAuditLog.create!(
      payroll_period: period,
      actor:          current_user,
      action_type:    :deleted,
      from_status:    period.status,
      to_status:      nil,
      metadata:       JSON.generate(period_label: period.period_label, deleted_at: Time.current.iso8601)
    )
    period.destroy!
    redirect_to admin_payroll_periods_path, notice: t("flash.payroll_period_deleted")
  rescue StandardError => e
    redirect_to admin_payroll_period_path(period), alert: e.message
  end

  private

  def find_period
    policy_scope(PayrollPeriod).find(params[:id])
  end
end
