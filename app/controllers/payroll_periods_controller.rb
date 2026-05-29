class PayrollPeriodsController < ApplicationController
  before_action :authenticate_user!

  def index
    base_scope = policy_scope(PayrollPeriod)

    if current_user.can?(:view_payroll)
      # Analytics-gated: KPI strip, filters, and per-period aggregate columns
      # all require `view_payroll_analytics`. Without it, a viewer just sees a
      # plain list of the periods they're authorized to access.
      if current_user.can?(:view_payroll_analytics)
        @summary         = build_index_summary(base_scope)
        @available_years = base_scope.distinct.order(period_year: :desc).pluck(:period_year)

        @filter_status = params[:status].presence
        @filter_year   = params[:year].to_i.nonzero?
        @filter_month  = params[:month].to_i.nonzero?

        filtered = base_scope
        filtered = filtered.where(status: @filter_status)     if @filter_status
        filtered = filtered.where(period_year:  @filter_year) if @filter_year
        filtered = filtered.where(period_month: @filter_month) if @filter_month
        @periods = filtered.order(period_year: :desc, period_month: :desc)

        period_ids = @periods.pluck(:id)
        if period_ids.any?
          @employee_counts   = PayrollEntry.where(payroll_period_id: period_ids).group(:payroll_period_id).count
          @period_net_totals = PayrollEntry.where(payroll_period_id: period_ids).group(:payroll_period_id).sum(:net_salary)
          @period_deductions = PayrollEntry.where(payroll_period_id: period_ids).group(:payroll_period_id).sum(:total_deductions)
          @period_overtime   = PayrollEntry.where(payroll_period_id: period_ids).group(:payroll_period_id).sum(:total_overtime)
        else
          @employee_counts = @period_net_totals = @period_deductions = @period_overtime = {}
        end
      else
        @periods = base_scope.order(period_year: :desc, period_month: :desc)
      end
    else
      @periods = base_scope.order(period_year: :desc, period_month: :desc)
      @my_entries = PayrollEntry
                      .where(user: current_user, payroll_period: @periods)
                      .index_by(&:payroll_period_id)
    end

    if current_user.can?(:view_payroll)
      @pending_review_period_ids = PayrollPeriodBranchReview
        .where(branch_id: current_user.managed_branch_ids, status: :pending)
        .where(payroll_period_id: @periods.select(:id))
        .pluck(:payroll_period_id).to_set
    end
  end

  def show
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period

    unless current_user.can?(:view_payroll)
      entry = @period.payroll_entries.find_by(user: current_user)
      if entry
        return redirect_to payroll_period_payroll_entry_path(@period, entry)
      else
        return redirect_to payroll_periods_path, alert: t("flash.no_payroll_entry")
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

    # Non-analytical management data (always loaded for any viewer with
    # `view_payroll`) — these are operational lookups, not financial aggregates.
    if current_user.can?(:view_payroll)
      @user_branch_names = load_user_branch_names(@entries.map(&:user_id))
      @last_regenerate   = @period.payroll_audit_logs
                                  .where(action_type: :regenerated)
                                  .includes(:actor)
                                  .order(created_at: :desc)
                                  .first
      @audit_logs        = @period.payroll_audit_logs.includes(:actor).order(created_at: :asc)
      @last_snapshot     = @period.payroll_snapshots.order(created_at: :desc).first
    end

    # Analytics-gated: KPI cards, insights, anomalies, period totals.
    # Without `view_payroll_analytics` a viewer sees the per-employee rows
    # they're authorized to see, but no organization-wide aggregates.
    if current_user.can?(:view_payroll_analytics)
      @overview  = build_period_overview(@entries)
      @insights  = Payroll::InsightsPresenter.new(period: @period, entries: @entries)
      @anomalies = Payroll::AnomalyDetector.new(
                     period:        @period,
                     entries:       @entries,
                     pending_count: @total_pending
                   ).detect
    end

    if current_user.can?(:manage_payroll)
      @all_branch_reviews = @period.payroll_period_branch_reviews
                                   .includes(:branch, :reviewer)
                                   .order("branches.name")
    end
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
      Payroll::NotificationService.notify(event: :submitted_for_review, period: @period, actor: current_user)
      redirect_to payroll_period_path(@period), notice: t("flash.payroll_submitted")
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def complete_branch_review
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :complete_branch_review?

    managed_branch_ids = current_user.managed_branch_ids
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
      Payroll::NotificationService.notify(event: :finalized, period: @period, actor: current_user)
      redirect_to payroll_period_path(@period), notice: t("flash.period_finalized")
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def mark_paid
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :mark_paid?

    result = Payroll::Approver.advance(period: @period, by: current_user)
    if result.success?
      Payroll::NotificationService.notify(event: :paid, period: @period, actor: current_user)
      redirect_to payroll_period_path(@period), notice: t("flash.period_paid")
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def approve_all_pending
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :approve_all_pending?

    unless @period.reviewable?
      return redirect_to payroll_period_path(@period),
                         alert: t("flash.period_not_reviewable")
    end

    pending_items = PayrollLineItem
      .joins(:payroll_entry)
      .where(payroll_entries: { payroll_period_id: @period.id })
      .where(review_status: :pending_review)
      .includes(:payroll_entry)

    return redirect_to payroll_period_path(@period),
                       alert: t("flash.no_pending_items") if pending_items.empty?

    entry_ids   = Set.new
    approved    = 0

    ActiveRecord::Base.transaction do
      pending_items.each do |item|
        item.update!(
          review_status: :approved,
          reviewed_by:   current_user,
          reviewed_at:   Time.current
        )
        entry_ids << item.payroll_entry_id
        approved  += 1
      end
      # Recalculate each entry exactly once rather than once per item
      PayrollEntry.where(id: entry_ids.to_a)
                  .includes(:payroll_line_items)
                  .each(&:recalculate_totals!)
    end

    PayrollAuditLog.create!(
      payroll_period: @period,
      actor:          current_user,
      action_type:    :adjustment_approved,
      metadata:       JSON.generate(bulk_approved: true, count: approved, approved_at: Time.current.iso8601)
    )

    redirect_to payroll_period_path(@period),
                notice: t("flash.all_pending_approved", count: approved)
  rescue StandardError => e
    redirect_to payroll_period_path(@period), alert: e.message
  end

  def regenerate
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :regenerate?

    result = Payroll::Regenerator.call(period: @period, regenerated_by: current_user)
    if result.success?
      employee_count = result.period.payroll_entries.count
      redirect_to payroll_period_path(result.period),
                  notice: t("flash.payroll_regenerated_stats", count: employee_count)
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def destroy
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :destroy?

    PayrollAuditLog.create!(
      payroll_period: @period,
      actor:          current_user,
      action_type:    :deleted,
      from_status:    @period.status,
      to_status:      nil,
      metadata:       JSON.generate(period_label: @period.period_label, deleted_at: Time.current.iso8601)
    )
    @period.destroy!
    redirect_to payroll_periods_path, notice: t("flash.payroll_period_deleted")
  rescue StandardError => e
    redirect_to payroll_period_path(@period), alert: e.message
  end

  private

  def period_params
    params.require(:payroll_period).permit(:year, :month)
  end

  def manager_branch_reviews
    return nil unless current_user.can?(:view_payroll)
    @period.payroll_period_branch_reviews
           .includes(:branch)
           .where(branch_id: current_user.managed_branch_ids)
  end

  def build_index_summary(scope)
    counts = scope.group(:status).count
    {
      total:        counts.values.sum,
      draft:        counts["draft"].to_i,
      under_review: counts["under_review"].to_i + counts["branch_review_completed"].to_i,
      finalized:    counts["finalized"].to_i,
      paid:         counts["paid"].to_i,
    }
  end

  def build_period_overview(entries)
    {
      total_employees:  entries.count,
      total_base:       entries.sum(&:base_salary),
      total_overtime:   entries.sum(&:total_overtime),
      total_deductions: entries.sum(&:total_deductions),
      total_bonuses:    entries.sum(&:total_bonuses),
      total_net:        entries.sum(&:net_salary),
      total_advances:   entries.sum(&:advances_deducted),
    }
  end

  def load_user_branch_names(user_ids)
    return {} if user_ids.empty?
    result = {}
    UserBranch.where(user_id: user_ids)
              .joins(:branch)
              .pluck(:user_id, "branches.name")
              .each { |uid, name| result[uid] ||= name }
    result
  end
end
