class PayrollPeriodsController < ApplicationController
  before_action :authenticate_user!

  def index
    @periods = policy_scope(PayrollPeriod)
                 .order(period_year: :desc, period_month: :desc)

    if current_user.employee?
      @my_entries = PayrollEntry
                      .where(user: current_user, payroll_period: @periods)
                      .index_by(&:payroll_period_id)
    end
  end

  def show
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period

    if current_user.employee?
      entry = @period.payroll_entries.find_by(user: current_user)
      if entry
        return redirect_to payroll_period_payroll_entry_path(@period, entry)
      else
        return redirect_to payroll_periods_path, alert: "No payroll entry found for this period."
      end
    end

    @entries = policy_scope(PayrollEntry)
                 .where(payroll_period: @period)
                 .includes(:user, :payroll_line_items)
                 .order("users.first_name, users.last_name")

    @pending_counts = @entries.each_with_object({}) do |entry, h|
      h[entry.id] = entry.payroll_line_items.count(&:pending_review?)
    end
    @total_pending = @pending_counts.values.sum

    @branch_reviews_for_manager = manager_branch_reviews
  end

  def new
    @period = PayrollPeriod.new
    authorize @period
  end

  def create
    authorize PayrollPeriod, :create?

    period = Payroll::PeriodGenerator.call(
      business:     current_user.business,
      year:         period_params[:year].to_i,
      month:        period_params[:month].to_i,
      generated_by: current_user
    )
    redirect_to payroll_period_path(period), notice: t("flash.payroll_generated", period: period.period_label)
  rescue ArgumentError, RuntimeError => e
    @period = PayrollPeriod.new
    flash.now[:alert] = e.message
    render :new, status: :unprocessable_entity
  end

  def submit_for_review
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :submit_for_review?

    result = Payroll::SubmitForReview.call(period: @period, by: current_user)
    if result.success?
      redirect_to payroll_period_path(@period), notice: t("flash.payroll_submitted")
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  # Branch manager marks all their branch reviews as complete for this period.
  def complete_branch_review
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :complete_branch_review?

    managed_branch_ids = Branch.where(branch_manager_id: current_user.id).pluck(:id)
    pending_reviews    = @period.payroll_period_branch_reviews
                                .where(branch_id: managed_branch_ids, status: :pending)
                                .includes(:branch)

    if pending_reviews.empty?
      return redirect_to payroll_period_path(@period),
                         alert: t("flash.no_pending_branch_reviews")
    end

    error = nil
    pending_reviews.each do |review|
      result = Payroll::BranchReviewCompleter.call(
        period:   @period,
        branch:   review.branch,
        reviewer: current_user,
        notes:    params[:notes]
      )
      error ||= result.error unless result.success?
    end

    if error
      redirect_to payroll_period_path(@period), alert: error
    else
      redirect_to payroll_period_path(@period), notice: t("flash.branch_review_completed")
    end
  end

  def finalize
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :finalize?

    result = Payroll::Approver.advance(period: @period, by: current_user)
    if result.success?
      redirect_to payroll_period_path(@period), notice: t("flash.period_finalized")
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  private

  def period_params
    params.require(:payroll_period).permit(:year, :month)
  end

  def manager_branch_reviews
    return nil unless current_user.branch_manager?
    managed_branch_ids = Branch.where(branch_manager_id: current_user.id).pluck(:id)
    @period.payroll_period_branch_reviews.where(branch_id: managed_branch_ids)
  end
end
