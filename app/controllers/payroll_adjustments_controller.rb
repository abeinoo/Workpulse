class PayrollAdjustmentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_period
  before_action :set_adjustment, only: [ :approve, :reject, :destroy ]

  def new
    @entry      = policy_scope(PayrollEntry).where(payroll_period: @period).find(params[:payroll_entry_id])
    @adjustment = PayrollAdjustment.new(payroll_period: @period, user: @entry.user)
    authorize @adjustment
  end

  def create
    entry       = policy_scope(PayrollEntry).where(payroll_period: @period).find(params[:payroll_entry_id])
    @adjustment = PayrollAdjustment.new(adjustment_params)
    @adjustment.payroll_period = @period
    @adjustment.user           = entry.user
    @adjustment.created_by     = current_user
    # Super admins' adjustments are auto-approved; managers' require review.
    @adjustment.review_status  = current_user.super_admin? ? "approved" : "pending_review"

    authorize @adjustment

    if @adjustment.save
      redirect_to payroll_period_payroll_entry_path(@period, entry),
                  notice: current_user.super_admin? ? "Adjustment added." : "Adjustment submitted for review."
    else
      @entry = entry
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    authorize @adjustment

    @adjustment.update!(
      review_status: "approved",
      reviewed_by:   current_user,
      reviewed_at:   Time.current
    )

    redirect_back fallback_location: entry_path_for(@adjustment),
                  notice: "Adjustment approved."
  rescue => e
    redirect_back fallback_location: payroll_period_path(@period), alert: e.message
  end

  def reject
    authorize @adjustment

    @adjustment.update!(
      review_status: "rejected",
      reviewed_by:   current_user,
      reviewed_at:   Time.current,
      review_notes:  params[:review_notes]
    )

    redirect_back fallback_location: entry_path_for(@adjustment),
                  notice: "Adjustment rejected."
  rescue => e
    redirect_back fallback_location: payroll_period_path(@period), alert: e.message
  end

  def destroy
    authorize @adjustment
    path = entry_path_for(@adjustment)
    @adjustment.destroy!
    redirect_back fallback_location: path, notice: "Adjustment removed."
  end

  private

  def set_period
    @period = policy_scope(PayrollPeriod).find(params[:payroll_period_id])
  end

  def set_adjustment
    @adjustment = policy_scope(PayrollAdjustment).find(params[:id])
  end

  def entry_path_for(adjustment)
    entry = PayrollEntry.find_by(payroll_period: @period, user: adjustment.user)
    entry ? payroll_period_payroll_entry_path(@period, entry) : payroll_period_path(@period)
  end

  def adjustment_params
    params.require(:payroll_adjustment).permit(:adjustment_type, :amount, :reason)
  end
end
