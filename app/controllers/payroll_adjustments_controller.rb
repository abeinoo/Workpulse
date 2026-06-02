class PayrollAdjustmentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_period
  before_action :set_adjustment, only: [ :approve, :reject, :destroy ]
  before_action :enforce_period_editable, only: [ :new, :create, :destroy ]

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
    # Adjustments created during payroll review ALWAYS start Pending. The creator
    # never approves their own entry — a separate approver with approve_adjustments
    # must review the resulting line item (creator != approver).
    @adjustment.review_status = "pending_review"

    authorize @adjustment

    if @adjustment.save
      materialise_line_item!(@adjustment, entry)
      log_adjustment_action!(:adjustment_added, @adjustment)
      redirect_to payroll_period_payroll_entry_path(@period, entry),
                  notice: t("payroll_adjustments.submitted_for_review")
    else
      @entry = entry
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    authorize @adjustment

    ActiveRecord::Base.transaction do
      @adjustment.approve_by!(current_user)
      sync_line_item!(@adjustment, "approved")
      log_adjustment_action!(:adjustment_approved, @adjustment)
    end

    redirect_back fallback_location: entry_path_for(@adjustment),
                  notice: t("flash.adjustment_approved")
  rescue => e
    redirect_back fallback_location: payroll_period_path(@period), alert: e.message
  end

  def reject
    authorize @adjustment

    ActiveRecord::Base.transaction do
      @adjustment.reject_by!(current_user, notes: params[:review_notes])
      sync_line_item!(@adjustment, "rejected")
      log_adjustment_action!(:adjustment_rejected, @adjustment)
    end

    redirect_back fallback_location: entry_path_for(@adjustment),
                  notice: t("flash.adjustment_rejected")
  rescue => e
    redirect_back fallback_location: payroll_period_path(@period), alert: e.message
  end

  def destroy
    authorize @adjustment
    path   = entry_path_for(@adjustment)
    entry  = PayrollEntry.find_by(payroll_period: @period, user: @adjustment.user)
    ActiveRecord::Base.transaction do
      line_item_for(@adjustment)&.destroy!
      log_adjustment_action!(:adjustment_removed, @adjustment)
      @adjustment.destroy!
      entry&.recalculate_totals!
    end
    redirect_back fallback_location: path, notice: t("flash.adjustment_removed")
  end

  private

  def set_period
    @period = policy_scope(PayrollPeriod).find(params[:payroll_period_id])
  end

  def enforce_period_editable
    return unless @period.locked?
    redirect_to payroll_period_path(@period),
                alert: t("payroll.locked.#{@period.lock_reason}")
  end

  def set_adjustment
    @adjustment = policy_scope(PayrollAdjustment).find(params[:id])
  end

  def entry_path_for(adjustment)
    entry = PayrollEntry.find_by(payroll_period: @period, user: adjustment.user)
    entry ? payroll_period_payroll_entry_path(@period, entry) : payroll_period_path(@period)
  end

  def adjustment_params
    params.require(:payroll_adjustment)
          .permit(:adjustment_type, :amount, :reason, :already_paid, :payment_method, :paid_at)
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
      review_status: adjustment.review_status,
      already_paid:  adjustment.already_paid?
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

  def log_adjustment_action!(action, adjustment)
    PayrollAuditLog.create!(
      payroll_period: @period,
      actor:          current_user,
      action_type:    action,
      metadata:       {
        adjustment_id:   adjustment.id,
        adjustment_type: adjustment.adjustment_type,
        amount:          adjustment.amount,
        already_paid:    adjustment.already_paid?,
        user_id:         adjustment.user_id
      }.to_json
    )
  end
end
