class AdjustmentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_adjustment, only: [ :approve, :reject, :destroy ]

  def index
    @adjustments = policy_scope(PayrollAdjustment)
                     .includes(:user, :created_by, :approved_by, :rejected_by)
                     .for_period(filter_year, filter_month)
                     .order(created_at: :desc)
    authorize PayrollAdjustment.new(business: current_user.business)
  end

  def new
    @adjustment = PayrollAdjustment.new(
      period_month: target_month,
      period_year:  target_year,
      business:     current_user.business
    )
    authorize @adjustment
    load_form_data
  end

  def create
    @adjustment = PayrollAdjustment.new(adjustment_params)
    @adjustment.business     = current_user.business
    @adjustment.created_by   = current_user
    @adjustment.review_status = current_user.owner? ? "approved" : "pending_review"

    if current_user.owner?
      @adjustment.approved_by = current_user
      @adjustment.approved_at = Time.current
      @adjustment.reviewed_by = current_user
      @adjustment.reviewed_at = Time.current
    end

    authorize @adjustment

    if @adjustment.save
      msg = current_user.owner? ? t("flash.adjustment_approved") : t("flash.request_submitted")
      redirect_to adjustments_path(period_month: @adjustment.period_month,
                                   period_year:  @adjustment.period_year),
                  notice: msg
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    authorize @adjustment

    @adjustment.update!(
      review_status: "approved",
      approved_by:   current_user,
      approved_at:   Time.current,
      reviewed_by:   current_user,
      reviewed_at:   Time.current
    )

    redirect_back fallback_location: adjustments_path, notice: t("flash.adjustment_approved")
  rescue => e
    redirect_back fallback_location: adjustments_path, alert: e.message
  end

  def reject
    authorize @adjustment

    @adjustment.update!(
      review_status: "rejected",
      rejected_by:   current_user,
      rejected_at:   Time.current,
      reviewed_by:   current_user,
      reviewed_at:   Time.current,
      review_notes:  params[:review_notes]
    )

    redirect_back fallback_location: adjustments_path, notice: t("flash.adjustment_rejected")
  rescue => e
    redirect_back fallback_location: adjustments_path, alert: e.message
  end

  def destroy
    authorize @adjustment
    period_month = @adjustment.period_month
    period_year  = @adjustment.period_year
    @adjustment.destroy!
    redirect_to adjustments_path(period_month: period_month, period_year: period_year),
                notice: t("flash.adjustment_removed")
  end

  private

  def set_adjustment
    @adjustment = policy_scope(PayrollAdjustment).find(params[:id])
  end

  def load_form_data
    @employees = manageable_employees
    @period_month = @adjustment.period_month || target_month
    @period_year  = @adjustment.period_year  || target_year
  end

  def manageable_employees
    if current_user.owner? || current_user.can?(:manage_adjustments)
      current_user.business.users.active.order(:first_name, :last_name)
    elsif current_user.manages_area?
      User.joins(:user_branches)
          .where(user_branches: { branch_id: current_user.area_managed_branch_ids })
          .active.order(:first_name, :last_name).distinct
    elsif current_user.manages_branch?
      current_user.managed_employees.active.order(:first_name, :last_name)
    else
      User.none
    end
  end

  def adjustment_params
    params.require(:payroll_adjustment)
          .permit(:adjustment_type, :amount, :reason, :user_id, :period_month, :period_year)
  end

  def filter_month
    params[:period_month]&.to_i || Date.current.month
  end

  def filter_year
    params[:period_year]&.to_i || Date.current.year
  end

  def target_month
    params[:period_month]&.to_i || Date.current.month
  end

  def target_year
    params[:period_year]&.to_i || Date.current.year
  end
end
