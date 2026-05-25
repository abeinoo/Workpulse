class AdjustmentsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_adjustment, only: [ :approve, :reject, :destroy ]

  def index
    authorize PayrollAdjustment.new(business: current_user.business)

    # Expose filter params as an instance variable so views can read them directly.
    # filter_params is private and Rails does not expose private methods to views.
    @filters = filter_params

    base_scope = policy_scope(PayrollAdjustment)
                   .includes(:user, :created_by, :approved_by, :rejected_by,
                              user: { profile_photo_attachment: :blob })

    # Period scope — used for summary stats (always full period, unfiltered by UI)
    @period_scope = base_scope.for_period(filter_year, filter_month)

    # Last-period scope for trend comparison
    lm = filter_month == 1 ? 12 : filter_month - 1
    ly = filter_month == 1 ? filter_year - 1 : filter_year
    last_period_scope = base_scope.for_period(ly, lm)

    @summary = Adjustments::SummaryData.new(@period_scope, last_period_scope).call

    # Apply UI filters on top of the period scope
    @adjustments = @period_scope
                     .by_type(@filters[:adjustment_type])
                     .by_status(@filters[:review_status])
                     .for_user(@filters[:user_id])
                     .then { |s|
                       @filters[:branch_id].present? ?
                         s.for_branch(@filters[:branch_id]) : s
                     }
                     .search_reason(@filters[:q])
                     .order(created_at: :desc)

    # Filter bar data
    @branches   = Branch.for_business(current_user.business).active.order(:name)
    @employees  = manageable_employees

    # Current filter state exposed for view
    @filter_month   = filter_month
    @filter_year    = filter_year
    @active_filters = @filters.values.any?(&:present?)
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
    @adjustment.business   = current_user.business
    @adjustment.created_by = current_user
    @adjustment.review_status = if @adjustment.already_paid?
                                  "approved"
                                elsif current_user.owner?
                                  "approved"
                                else
                                  "pending_review"
                                end

    if @adjustment.review_status == "approved"
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
    month = @adjustment.period_month
    year  = @adjustment.period_year
    @adjustment.destroy!
    redirect_to adjustments_path(period_month: month, period_year: year),
                notice: t("flash.adjustment_removed")
  end

  private

  def set_adjustment
    @adjustment = policy_scope(PayrollAdjustment).find(params[:id])
  end

  def load_form_data
    @employees    = manageable_employees
    @period_month = @adjustment.period_month || target_month
    @period_year  = @adjustment.period_year  || target_year
  end

  def manageable_employees
    EmployeeScope.new(current_user).relation.active.order(:first_name, :last_name)
  end

  def adjustment_params
    params.require(:payroll_adjustment)
          .permit(:adjustment_type, :amount, :reason, :user_id,
                  :period_month, :period_year,
                  :already_paid, :payment_method, :paid_at)
  end

  def filter_params
    params.permit(:adjustment_type, :review_status, :user_id, :branch_id, :q)
  end

  def filter_month
    params[:period_month]&.to_i.presence || Date.current.month
  end

  def filter_year
    params[:period_year]&.to_i.presence || Date.current.year
  end

  def target_month
    params[:period_month]&.to_i.presence || Date.current.month
  end

  def target_year
    params[:period_year]&.to_i.presence || Date.current.year
  end
end
