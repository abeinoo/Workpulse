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

    # Show ALL adjustments by default; every filter is optional and combinable.
    filtered = base_scope
                 .period_on_or_after(parsed_date(@filters[:date_from]))
                 .period_on_or_before(parsed_date(@filters[:date_to]))
                 .by_type(@filters[:adjustment_type])
                 .by_status(@filters[:review_status])
                 .for_user(@filters[:user_id])
                 .then { |s|
                   @filters[:branch_id].present? ?
                     s.for_branch(@filters[:branch_id]) : s
                 }
                 .search_reason(@filters[:q])

    # Summary reflects the current (filtered) result set. No order — SummaryData
    # groups/aggregates and an ORDER BY would conflict with its GROUP BY.
    @summary     = Adjustments::SummaryData.new(filtered).call
    @adjustments = filtered.order(created_at: :desc)

    # Adjustment Analytics & Reports are restricted to Business-scope users
    # (owners/admins). Branch- and area-scope managers and employees see the list
    # but not the aggregate analytics. Both the UI and the policy enforce this.
    @can_view_analytics = policy(PayrollAdjustment.new(business: current_user.business)).analytics?

    # Row selection + bulk Approve/Reject is only offered to users who can review
    # adjustments (approve_adjustments). Employees never see the checkboxes/actions.
    @can_review_bulk = policy(PayrollAdjustment.new(business: current_user.business)).bulk_approve?

    # Filter bar data
    @branches   = Branch.for_business(current_user.business).active.order(:name)
    @employees  = manageable_employees

    # Current filter state exposed for view
    @active_filters = @filters.values.any?(&:present?)
    @default_month  = Date.current.month
    @default_year   = Date.current.year
  end

  def show
    @adjustment = policy_scope(PayrollAdjustment)
                    .includes(:user, :created_by, :approved_by, :rejected_by, :reviewed_by, :payroll_period)
                    .find(params[:id])
    authorize @adjustment
  end

  # Quick-action shortcuts pass ?adjustment_type=… so the form opens with the
  # matching option preselected. Aliases ("deduction", "bonus") are normalised to
  # real enum values; an absent/unknown value falls back to the form default.
  ADJUSTMENT_TYPE_ALIASES = {
    "deduction" => "manual_deduction",
    "bonus"     => "cash_incentive",
    "incentive" => "cash_incentive"
  }.freeze

  def new
    @adjustment = PayrollAdjustment.new(business: current_user.business)
    @adjustment.adjustment_type = preselected_adjustment_type
    authorize @adjustment
    load_form_data
  end

  def create
    @adjustment = PayrollAdjustment.new(adjustment_params)
    assign_period(@adjustment)
    @adjustment.business   = current_user.business
    @adjustment.created_by = current_user
    # Adjustments start Pending and require a separate approver (see
    # creator_is_not_approver / PayrollAdjustmentPolicy). The single exception:
    # an owner-created adjustment is auto-approved at creation, since the owner is
    # the ultimate approval authority (apply_owner_auto_approval no-ops otherwise).
    @adjustment.review_status = "pending_review"
    @adjustment.apply_owner_auto_approval

    authorize @adjustment

    if @adjustment.save
      redirect_to adjustments_path(period_month: @adjustment.period_month,
                                   period_year:  @adjustment.period_year),
                  notice: t("flash.request_submitted")
    else
      load_form_data
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    authorize @adjustment

    @adjustment.approve_by!(current_user)

    redirect_back fallback_location: adjustments_path, notice: t("flash.adjustment_approved")
  rescue => e
    redirect_back fallback_location: adjustments_path, alert: e.message
  end

  def reject
    authorize @adjustment

    @adjustment.reject_by!(current_user, notes: params[:review_notes])

    redirect_back fallback_location: adjustments_path, notice: t("flash.adjustment_rejected")
  rescue => e
    redirect_back fallback_location: adjustments_path, alert: e.message
  end

  # Bulk approve/reject of the selected pending adjustments. Each row is processed
  # individually (audit fields stay accurate); already-decided rows are skipped and
  # rows the user may not review (e.g. ones they created) are counted as failed.
  # Selection runs through policy_scope, so a reviewer can only ever act on rows
  # within their data scope.
  def bulk_approve
    authorize PayrollAdjustment.new(business: current_user.business), :bulk_approve?

    result = Adjustments::BulkReview.approve(
      adjustments: selected_adjustments,
      reviewer:    current_user
    )
    redirect_back fallback_location: adjustments_path, **bulk_review_flash(result)
  end

  def bulk_reject
    authorize PayrollAdjustment.new(business: current_user.business), :bulk_reject?

    result = Adjustments::BulkReview.reject(
      adjustments: selected_adjustments,
      reviewer:    current_user,
      notes:       params[:review_notes].presence
    )
    redirect_back fallback_location: adjustments_path, **bulk_review_flash(result)
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

  # The chosen rows, always re-scoped through policy_scope so a reviewer can never
  # act on an adjustment outside their data scope, whatever ids were posted.
  def selected_adjustments
    policy_scope(PayrollAdjustment).where(id: Array(params[:adjustment_ids])).to_a
  end

  # Builds the redirect flash for a bulk review outcome, e.g.
  # "Approved: 18 · Skipped: 2 · Failed: 1". A notice when anything succeeded,
  # otherwise an alert (nothing actionable was selected).
  def bulk_review_flash(result)
    return { alert: t("adjustments.bulk.none_selected") } unless result.any_selected?

    message = t("adjustments.bulk.#{result.action}_result",
                succeeded: result.succeeded, skipped: result.skipped, failed: result.failed)

    result.any_succeeded? ? { notice: message } : { alert: message }
  end

  def load_form_data
    @employees           = manageable_employees
    @selectable_periods  = Adjustments::SelectablePeriods.new(current_user.business).options
    @selected_period_key = selected_period_key
  end

  def manageable_employees
    # Resolve scope most-specific-first (manage_adjustments → view_payroll →
    # view_employees) so a business-wide manager sees every employee. Falls back
    # to the managed hierarchy when none is configured.
    EmployeeScope.new(current_user)
                 .for_permissions(:manage_adjustments, :view_payroll, :view_employees)
                 .active.order(:first_name, :last_name)
  end

  # Resolves the ?adjustment_type=… param to a valid, writable adjustment type,
  # or nil when absent/unrecognised (preserving the form's default behaviour).
  def preselected_adjustment_type
    raw = params[:adjustment_type].presence
    return nil unless raw

    normalized = ADJUSTMENT_TYPE_ALIASES.fetch(raw, raw)
    normalized if PayrollAdjustment::ADJUSTMENT_TYPES.include?(normalized)
  end

  def adjustment_params
    params.require(:payroll_adjustment)
          .permit(:adjustment_type, :amount, :reason, :user_id,
                  :period_month, :period_year,
                  :already_paid, :payment_method, :paid_at)
  end

  # The new form posts the target period as a single "YYYY-M" select value.
  # Manual creation must explicitly pick a period — there is no silent fallback
  # to the current month.
  def assign_period(adjustment)
    key = params.dig(:payroll_adjustment, :period_key).presence
    return unless key && key =~ /\A(\d{4})-(\d{1,2})\z/

    adjustment.period_year  = Regexp.last_match(1).to_i
    adjustment.period_month = Regexp.last_match(2).to_i
  end

  # Pre-selected period for the form: an explicit param wins, otherwise the first
  # open period offered by the dropdown (or nil → user must choose).
  def selected_period_key
    if params[:period_year].present? && params[:period_month].present?
      "#{params[:period_year].to_i}-#{params[:period_month].to_i}"
    else
      @selectable_periods.first&.last
    end
  end

  def filter_params
    params.permit(:adjustment_type, :review_status, :user_id, :branch_id, :q,
                  :date_from, :date_to)
  end

  def parsed_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError
    nil
  end
end
