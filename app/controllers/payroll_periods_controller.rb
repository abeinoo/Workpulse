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

    @needs_review_count = @entries.count(&:needs_review?)
    @filter_needs_review = params[:needs_review] == "1"
    @entries = @entries.select(&:needs_review?) if @filter_needs_review

    @pending_counts = @entries.each_with_object({}) do |entry, h|
      h[entry.id] = entry.payroll_line_items.count(&:pending_review?)
    end
    @total_pending = @pending_counts.values.sum

    @branch_reviews_for_manager    = manager_branch_reviews
    @has_changes_requested_reviews = @period.payroll_period_branch_reviews.changes_requested.exists?

    # Non-analytical, non-sensitive operational lookups.
    if current_user.can?(:view_payroll)
      @user_branch_names = load_user_branch_names(@entries.map(&:user_id))
      @last_snapshot     = @period.payroll_snapshots.order(created_at: :desc).first
    end

    # Audit trail is sensitive (who did what, when, why) — gated separately.
    if current_user.can?(:view_payroll_audit_log)
      @last_regenerate = @period.payroll_audit_logs
                                .where(action_type: :regenerated)
                                .includes(:actor)
                                .order(created_at: :desc)
                                .first
      @audit_logs      = @period.payroll_audit_logs.includes(:actor).order(created_at: :asc)
    end

    # Analytics-gated: KPI cards, insights, anomalies, period totals.
    # Without `view_payroll_analytics` a viewer sees the per-employee rows
    # they're authorized to see, but no organization-wide aggregates.
    if current_user.can?(:view_payroll_analytics)
      @overview          = build_period_overview(@entries)
      @financial_summary = Payroll::PeriodFinancialSummary.new(@entries)
      @insights  = Payroll::InsightsPresenter.new(period: @period, entries: @entries)
      @anomalies = Payroll::AnomalyDetector.new(
                     period:        @period,
                     entries:       @entries,
                     pending_count: @total_pending
                   ).detect
    end

    # Bank-transfer export summary — shown as a banner above the download button
    # on finalised/paid periods. Reuses the policy-scoped @entries so the figures
    # match exactly what the CSV will contain.
    if policy(@period).export_payroll_bank_csv?
      @bank_transfer_summary =
        Reports::BankTransferCsvExporter.new(period: @period, entries: @entries).summary
    end

    # The all-branches review progress table is intended for finance/admin
    # users overseeing the whole period — gated on the new period-level
    # permissions that imply business-wide payroll responsibility.
    if current_user.can?(:finalize_payroll) || current_user.can?(:pay_payroll)
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
      redirect_to payroll_period_path(@period), notice: t("flash.payroll_submitted")
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def complete_branch_review
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :complete_branch_review?

    authorized_branch_ids = reviewable_branch_ids_for(current_user)
    pending_reviews       = @period.payroll_period_branch_reviews
                                   .where(branch_id: authorized_branch_ids, status: :pending)
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

  def request_changes
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :request_changes?

    comment = params[:comment].to_s.strip
    if comment.blank?
      return redirect_to payroll_period_path(@period),
                         alert: t("flash.changes_request_comment_required")
    end

    authorized_branch_ids = reviewable_branch_ids_for(current_user)
    pending_reviews       = @period.payroll_period_branch_reviews
                                   .where(branch_id: authorized_branch_ids, status: :pending)
                                   .includes(:branch)

    if pending_reviews.empty?
      return redirect_to payroll_period_path(@period),
                         alert: t("flash.no_pending_branch_reviews")
    end

    error = nil
    pending_reviews.each do |review|
      result = Payroll::ChangesRequester.call(
        period:   @period,
        branch:   review.branch,
        reviewer: current_user,
        comment:  comment
      )
      error ||= result.error unless result.success?
    end

    if error
      redirect_to payroll_period_path(@period), alert: error
    else
      redirect_to payroll_period_path(@period), notice: t("flash.changes_requested")
    end
  end

  def resubmit_for_review
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :resubmit_for_review?

    result = Payroll::SubmitForReview.call(period: @period, by: current_user)
    if result.success?
      redirect_to payroll_period_path(@period), notice: t("flash.resubmitted_for_review")
    else
      redirect_to payroll_period_path(@period), alert: result.error
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

  def mark_paid
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :mark_paid?

    result = Payroll::Approver.advance(period: @period, by: current_user)
    if result.success?
      redirect_to payroll_period_path(@period), notice: t("flash.period_paid")
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def approve_all_pending
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :approve_all_pending?

    unless @period.editable?
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

    entry_ids = Set.new
    approved  = 0
    skipped   = 0

    ActiveRecord::Base.transaction do
      pending_items.each do |item|
        # Adjustment-sourced items obey the single approval rule: the bulk approver
        # must hold approve_adjustments AND must not be the adjustment's creator.
        # Such items are skipped (not approved) when the rule is not satisfied, so a
        # manager can never self-approve their own adjustments via "approve all".
        # System-generated attendance items have no creator and stay gated only by
        # approve_payroll_items (the action-level authorization above).
        if item.adjustment_sourced? &&
           !Payroll::AdjustmentApproval.permitted?(reviewer: current_user, creator: item.source_creator)
          skipped += 1
          next
        end

        item.update!(
          review_status: :approved,
          reviewed_by:   current_user,
          reviewed_at:   Time.current
        )
        item.source_adjustment&.approve_by!(current_user)
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
      metadata:       JSON.generate(bulk_approved: true, count: approved, skipped: skipped, approved_at: Time.current.iso8601)
    )

    notice = t("flash.all_pending_approved", count: approved)
    notice += " #{t('flash.pending_skipped_self', count: skipped)}" if skipped.positive?
    redirect_to payroll_period_path(@period), notice: notice
  rescue StandardError => e
    redirect_to payroll_period_path(@period), alert: e.message
  end

  def adjust_overtime
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :adjust_overtime?

    # Restrict to entries the actor is authorised to see within this period.
    entry_ids = policy_scope(PayrollEntry).where(payroll_period: @period, id: params[:entry_ids]).pluck(:id)

    result = Payroll::BulkOvertimeOverrider.call(
      period:    @period,
      entry_ids: entry_ids,
      bulk_mode: params[:bulk_mode],
      value:     params[:value],
      reason:    params[:reason],
      actor:     current_user
    )

    if result.success?
      notice = t("payroll.overtime_override.flash.bulk_applied", count: result.applied)
      notice += " #{t('payroll.overtime_override.flash.bulk_skipped', count: result.skipped)}" if result.skipped.positive?
      redirect_to payroll_period_path(@period), notice: notice
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def waive_deductions
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :waive_deductions?

    # Restrict to entries the actor is authorised to see within this period.
    entry_ids = policy_scope(PayrollEntry).where(payroll_period: @period, id: params[:entry_ids]).pluck(:id)

    result = Payroll::BulkDeductionWaiver.call(
      period:    @period,
      entry_ids: entry_ids,
      action:    params[:waiver_action],
      reason:    params[:reason],
      actor:     current_user
    )

    if result.success?
      notice = t("payroll.deduction_waiver.flash.bulk_applied", count: result.applied)
      notice += " #{t('payroll.deduction_waiver.flash.bulk_skipped', count: result.skipped)}" if result.skipped.positive?
      redirect_to payroll_period_path(@period), notice: notice
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def mark_all_reviewed
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :mark_all_reviewed?

    # entry_ids restricts to a specific set (e.g. a branch manager's own
    # branch); absent, every flagged entry in the period is cleared.
    entry_ids = params[:entry_ids].presence &&
                policy_scope(PayrollEntry).where(payroll_period: @period, id: params[:entry_ids]).pluck(:id)

    result = Payroll::BulkEntryReviewClearer.call(period: @period, actor: current_user, entry_ids: entry_ids)

    if result.success?
      redirect_to payroll_period_path(@period), notice: t("payroll.needs_review.flash.bulk_cleared", count: result.cleared)
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
  end

  def export_bank_transfer
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :export_payroll_bank_csv?

    entries  = policy_scope(PayrollEntry).where(payroll_period: @period)
    exporter = Reports::BankTransferCsvExporter.new(period: @period, entries: entries)

    send_data exporter.to_csv, filename: exporter.filename, type: "text/csv"
  end

  # "إعادة احتساب الوقت الإضافي" — read-only preview; nothing is written.
  def recalculate_overtime_preview
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :recalculate_overtime?

    result = Payroll::OvertimeRecalculator.new(period_id: @period.id, actor: current_user).preview
    return redirect_to(payroll_period_path(@period), alert: result.error) unless result.ok?

    @preview = result.preview
  end

  def recalculate_overtime
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :recalculate_overtime?

    result = Payroll::OvertimeRecalculator.new(period_id: @period.id, actor: current_user)
                                          .apply!(expected_digest: params[:preview_digest])
    if result.ok?
      redirect_to payroll_period_path(@period),
                  notice: t("payroll.overtime_recalculation.flash.applied", count: result.preview.affected_count)
    elsif result.preview
      redirect_to recalculate_overtime_preview_payroll_period_path(@period), alert: result.error
    else
      redirect_to payroll_period_path(@period), alert: result.error
    end
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

  def reopen
    @period = policy_scope(PayrollPeriod).find(params[:id])
    authorize @period, :reopen?

    result = Payroll::Reopener.call(
      period: @period,
      by:     current_user,
      reason: params[:reason]
    )

    if result.success?
      redirect_to payroll_period_path(@period), notice: t("flash.period_reopened")
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
    return nil unless current_user.can?(:complete_branch_review)
    @period.payroll_period_branch_reviews
           .includes(:branch)
           .where(branch_id: reviewable_branch_ids_for(current_user))
  end

  # Branches a user is allowed to complete reviews for. Honors the configured
  # `complete_branch_review` data scope:
  #   - business: every branch in the business
  #   - branch / area / default: structural relationships
  #     (branches where the user is branch_manager_id or area_manager_id).
  def reviewable_branch_ids_for(user)
    case user.scope_for(:complete_branch_review)
    when "business"
      user.business.branches.pluck(:id)
    else
      (user.managed_branch_ids + user.area_managed_branch_ids).uniq
    end
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
    ShiftAssignment.branch_names_by_user(
      user_ids, from: @period.period_start, to: @period.period_end
    )
  end
end
