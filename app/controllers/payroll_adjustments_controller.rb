class PayrollAdjustmentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_period
  before_action :set_adjustment, only: [ :approve, :reject, :destroy ]

  def new
    @entry      = policy_scope(PayrollEntry).where(payroll_period: @period).find(params[:payroll_entry_id])
    @adjustment = PayrollAdjustment.new(payroll_period: @period, user: @entry.user, business: current_user.business)
    authorize @adjustment
  end

  def create
    entry       = policy_scope(PayrollEntry).where(payroll_period: @period).find(params[:payroll_entry_id])
    @adjustment = PayrollAdjustment.new(adjustment_params)
    @adjustment.payroll_period = @period
    @adjustment.user           = entry.user
    @adjustment.business       = current_user.business
    @adjustment.period_month   = @period.period_month
    @adjustment.period_year    = @period.period_year
    @adjustment.created_by     = current_user
    # Super admins' adjustments are auto-approved; managers' require review.
    @adjustment.review_status  = current_user.owner? ? "approved" : "pending_review"

    authorize @adjustment

    if @adjustment.save
      materialise_line_item!(@adjustment, entry)
      redirect_to payroll_period_payroll_entry_path(@period, entry),
                  notice: current_user.owner? ? "Adjustment added." : "Adjustment submitted for review."
    else
      @entry = entry
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    authorize @adjustment

    ActiveRecord::Base.transaction do
      @adjustment.update!(
        review_status: "approved",
        reviewed_by:   current_user,
        reviewed_at:   Time.current
      )
      sync_line_item!(@adjustment, "approved")
    end

    redirect_back fallback_location: entry_path_for(@adjustment),
                  notice: "Adjustment approved."
  rescue => e
    redirect_back fallback_location: payroll_period_path(@period), alert: e.message
  end

  def reject
    authorize @adjustment

    ActiveRecord::Base.transaction do
      @adjustment.update!(
        review_status: "rejected",
        reviewed_by:   current_user,
        reviewed_at:   Time.current,
        review_notes:  params[:review_notes]
      )
      sync_line_item!(@adjustment, "rejected")
    end

    redirect_back fallback_location: entry_path_for(@adjustment),
                  notice: "Adjustment rejected."
  rescue => e
    redirect_back fallback_location: payroll_period_path(@period), alert: e.message
  end

  def destroy
    authorize @adjustment
    path   = entry_path_for(@adjustment)
    entry  = PayrollEntry.find_by(payroll_period: @period, user: @adjustment.user)
    ActiveRecord::Base.transaction do
      line_item_for(@adjustment)&.destroy!
      @adjustment.destroy!
      entry&.recalculate_totals!
    end
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

  # Creates a PayrollLineItem for a review-time adjustment so it immediately
  # appears on the payroll entry page.
  def materialise_line_item!(adjustment, entry)
    entry.payroll_line_items.create!(
      item_type:     adjustment.line_item_type,
      amount:        adjustment.signed_amount,
      description:   adjustment.reason,
      source_type:   "PayrollAdjustment",
      source_id:     adjustment.id,
      review_status: adjustment.review_status
    )
    entry.recalculate_totals!
  end

  # Finds the line item that was created for this adjustment and updates its status.
  def sync_line_item!(adjustment, new_status)
    li = line_item_for(adjustment)
    return unless li

    li.update!(review_status: new_status)
    li.payroll_entry.recalculate_totals!
  end

  def line_item_for(adjustment)
    PayrollLineItem.find_by(source_type: "PayrollAdjustment", source_id: adjustment.id)
  end
end
