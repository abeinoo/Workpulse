class EmployeeRequestsController < ApplicationController
  before_action :authenticate_user!

  PER_PAGE_OPTIONS = [ 25, 50, 100 ].freeze
  DEFAULT_PER_PAGE = 25

  def index
    @filters = filter_params

    # Base filtered scope (no includes, no pagination — used for counts)
    base = policy_scope(EmployeeRequest)
             .with_status(@filters[:status])
             .with_request_type(@filters[:request_type])
             .for_user(@filters[:user_id])
             .then { |s| @filters[:branch_id].present? ? s.for_branch(@filters[:branch_id]) : s }
             .requested_on_or_after(parsed_date(@filters[:date_from]))
             .requested_on_or_before(parsed_date(@filters[:date_to]))

    # Status summary counts using the same filters minus the status filter,
    # so all tiles remain visible regardless of which status is selected.
    count_base = policy_scope(EmployeeRequest)
                   .with_request_type(@filters[:request_type])
                   .for_user(@filters[:user_id])
                   .then { |s| @filters[:branch_id].present? ? s.for_branch(@filters[:branch_id]) : s }
                   .requested_on_or_after(parsed_date(@filters[:date_from]))
                   .requested_on_or_before(parsed_date(@filters[:date_to]))
    @status_counts = count_base.group(:status).count

    @total_count = base.count

    # Sorting — default is priority order (pending → awaiting payment → paid → rejected).
    # Explicit sort columns override it; CSV export always uses created_at DESC (unchanged).
    sort_col = %w[created_at employee_name request_type status].include?(@filters[:sort]) ? @filters[:sort] : nil
    sort_dir = @filters[:dir] == "asc" ? "asc" : "desc"

    sorted = if sort_col.nil?
               base.left_joins(:advance)
                   .order(Arel.sql(EmployeeRequest.priority_case_sql))
                   .order(created_at: :desc)
             else
               case sort_col
               when "created_at"    then base.order(created_at: sort_dir.to_sym)
               when "employee_name" then base.left_joins(:user).order(Arel.sql("users.first_name #{sort_dir}, users.last_name #{sort_dir}"))
               when "request_type"  then base.order(request_type: sort_dir.to_sym)
               when "status"        then base.order(status: sort_dir.to_sym)
               end
             end

    # Pagination
    @per_page    = PER_PAGE_OPTIONS.include?(@filters[:per_page].to_i) ? @filters[:per_page].to_i : DEFAULT_PER_PAGE
    @page        = [ @filters[:page].to_i, 1 ].max
    @total_pages = [ (@total_count.to_f / @per_page).ceil, 1 ].max
    @page        = [ @page, @total_pages ].min

    @requests = sorted.includes(:user, :advance).offset((@page - 1) * @per_page).limit(@per_page)

    # Filter-bar option sources, scoped to what this user may see.
    @filter_employees = requestable_employees.active.order(:first_name, :last_name)
    @filter_branches  = Branch.for_business(current_user.business).active.order(:name)
    @active_filters   = @filters.slice(:status, :request_type, :user_id, :branch_id, :date_from, :date_to).values.any?(&:present?)

    respond_to do |format|
      format.html
      format.csv do
        authorize EmployeeRequest, :index?
        # Re-fetch without pagination so the export covers all matching records
        @csv_requests = base.includes(:user, :reviewed_by).order(created_at: :desc)
        send_data salary_advances_csv, filename: "salary_advances_#{Date.current}.csv",
                  type: "text/csv"
      end
    end
  end

  def show
    @request = policy_scope(EmployeeRequest).find(params[:id])
    authorize @request
    if @request.punch_correction?
      @attendance_record = AttendanceRecord.find_by(
        user:      @request.user,
        work_date: @request.requested_for_date
      )
      # Validation data is computed only for reviewers, so it never reaches the
      # requester's rendered page (not merely hidden).
      @reviewer_view = policy(@request).review_details?
      if @reviewer_view
        # A refused approval returns here with the reviewer's chosen final
        # datetime so the checks (and the form) reflect exactly what they entered.
        @review_date, @review_time = review_param_datetime
        @assessment = Requests::PunchCorrectionAssessment.for(@request, date: @review_date, time_str: @review_time)
      end
    end
  end

  def new
    @for_user              = resolve_for_user
    @request               = EmployeeRequest.new
    authorize @request
    prefill_from_params(@request)
    target_user            = @for_user || current_user
    @managed_employees     = managed_employees_for_form
    @permission_limits     = permission_limits_for(target_user)
    @allowed_request_types = allowed_request_types_for(target_user)
    @advance_limit         = advance_limit_for(target_user)
    @punch_check_ins       = punch_check_ins_for(target_user)
  end

  def create
    @request      = EmployeeRequest.new(request_params)
    @request.user = resolve_for_user || current_user

    authorize @request

    # Punch corrections outside the expected attendance window are held back
    # once with a warning; the employee resubmits with explicit acknowledgement.
    # Nothing about the proposed date/time is changed.
    if @request.punch_correction? && @request.valid?
      assessment = Requests::PunchCorrectionAssessment.for(@request)
      unless assessment.inside_window? || params.dig(:employee_request, :acknowledge_out_of_window) == "1"
        @window_warning = assessment
      end
    end

    if @window_warning.nil? && Requests::Submitter.call(request: @request, actor: current_user)
      redirect_to employee_requests_path, notice: t("flash.request_submitted")
    else
      @for_user              = @request.user unless @request.user == current_user
      @managed_employees     = managed_employees_for_form
      @permission_limits     = permission_limits_for(@request.user)
      @allowed_request_types = allowed_request_types_for(@request.user)
      @advance_limit         = advance_limit_for(@request.user)
      @punch_check_ins       = punch_check_ins_for(@request.user)
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    @request = policy_scope(EmployeeRequest).find(params[:id])
    authorize @request

    result = Requests::Approver.approve(
      request:       @request,
      reviewed_by:   current_user,
      response_note: params[:response_note],
      approved_at:   params[:approved_at],
      confirm_out_of_window: params[:confirm_out_of_window]
    )

    if result.success?
      redirect_back fallback_location: employee_request_path(@request), notice: t("flash.request_approved")
    elsif @request.punch_correction?
      redirect_to employee_request_path(@request, params.permit(:approved_at).to_h),
                  alert: result.error
    else
      redirect_back fallback_location: employee_request_path(@request), alert: result.error
    end
  end

  def reject
    @request = policy_scope(EmployeeRequest).find(params[:id])
    authorize @request

    result = Requests::Approver.reject(
      request:       @request,
      reviewed_by:   current_user,
      response_note: params[:response_note]
    )

    if result.success?
      redirect_back fallback_location: employee_request_path(@request), notice: t("flash.request_rejected")
    else
      redirect_back fallback_location: employee_request_path(@request), alert: result.error
    end
  end

  def pay
    @request = policy_scope(EmployeeRequest).find(params[:id])
    authorize @request

    result = Requests::Approver.pay(request: @request, paid_by: current_user)

    if result.success?
      redirect_back fallback_location: employee_request_path(@request),
                    notice: t("flash.advance_paid")
    else
      redirect_back fallback_location: employee_request_path(@request), alert: result.error
    end
  end

  def cancel
    @request = policy_scope(EmployeeRequest).find(params[:id])
    authorize @request

    result = Requests::Canceller.cancel(
      request:      @request,
      cancelled_by: current_user,
      reason:       params[:cancellation_reason]
    )

    if result.success?
      redirect_back fallback_location: employee_request_path(@request),
                    notice: t("flash.request_cancelled")
    else
      redirect_back fallback_location: employee_request_path(@request), alert: result.error
    end
  end

  # Bulk "Mark Selected as Paid": disburses the chosen approved salary advances
  # in a single transaction, skipping and reporting any that are no longer
  # payable. Selection is scoped through policy_scope so an accountant can only
  # ever act on requests within their data scope.
  def bulk_pay
    authorize EmployeeRequest, :bulk_pay?

    requests = policy_scope(EmployeeRequest)
                 .includes(:user, :advance)
                 .where(id: Array(params[:request_ids]))

    result = Requests::BulkPaymentService.call(
      requests: requests.to_a,
      paid_by:  current_user,
      paid_at:  params[:paid_at],
      notes:    params[:notes]
    )

    redirect_to employee_requests_path, **bulk_pay_flash(result)
  end

  def mark_all_paid
    authorize EmployeeRequest, :pay?

    pending_advances = policy_scope(EmployeeRequest)
                         .where(status: "approved")
                         .select(&:salary_advance?)
                         .reject { |r| r.advance.present? }

    result = Requests::Approver.pay_all(requests: pending_advances, paid_by: current_user)

    if result.errors.empty?
      redirect_to employee_requests_path,
                  notice: t("flash.advances_paid_#{result.paid_count == 1 ? 'one' : 'other'}", count: result.paid_count)
    else
      redirect_to employee_requests_path,
                  alert: t("flash.advances_partial_failure", errors: result.errors.join("; "))
    end
  end

  private

  # Reviewer-selected final punch datetime carried back to the show page after
  # a refused approval, as [date, "HH:MM"]; ignored unless pending and valid.
  def review_param_datetime
    return unless @request.pending?

    parsed = Requests::Approver.parse_approved_at(params[:approved_at], business: @request.user.business)
    parsed.is_a?(Array) ? parsed : nil
  end

  # Builds the redirect flash for a bulk-pay outcome. Returns a hash suitable for
  # splatting into redirect_to (notice and/or alert).
  def bulk_pay_flash(result)
    if result.any_paid?
      total  = helpers.format_currency(result.total_amount, precision: 0)
      notice = t("flash.bulk_pay.paid", count: result.paid_count, total: total)
      flash  = { notice: notice }
      if result.skipped_count.positive?
        flash[:alert] = t("flash.bulk_pay.skipped", count: result.skipped_count)
      end
      flash
    elsif result.skipped_count.positive?
      { alert: t("flash.bulk_pay.none_paid", count: result.skipped_count) }
    else
      { alert: t("flash.bulk_pay.none_selected") }
    end
  end

  # Whitelisted index filters. Kept in the URL query string (GET form) so they
  # survive reloads, the CSV export link, and back/forward navigation.
  def filter_params
    params.permit(:status, :request_type, :user_id, :branch_id, :date_from, :date_to,
                  :sort, :dir, :page, :per_page)
  end

  def parsed_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError
    nil
  end

  # The advance limit is derived from the employee's salary — for a monthly
  # salary it is a fixed percentage of it, so the salary can be read off it. For
  # one's own request it is shown as before. On behalf of another employee it is
  # shown only to an actor who may view that employee's salary
  # (SalaryProfilePolicy#view_salary?) and recorded as a salary view; anyone else
  # gets no figures (@advance_limit_hidden) — the limit is still enforced on
  # submission.
  def advance_limit_for(target_user)
    @advance_limit_hidden = false
    limit = Salary::AdvanceEligibilityCalculator.for(user: target_user)
    return limit if limit.nil? || target_user == current_user

    unless policy(SalaryProfile.new(user_id: target_user.id)).view_salary?
      @advance_limit_hidden = true
      return nil
    end

    unless limit.no_profile?
      Salary::ViewAudit.record(actor: current_user, employee: target_user,
                               profiles: [ SalaryProfile.current_for(target_user) ], source: "request_advance_limit")
    end
    limit
  end

  def resolve_for_user
    return nil unless current_user.can?(:approve_requests)
    id = params[:for_user_id].presence || params.dig(:employee_request, :for_user_id).presence
    return nil unless id
    # Honour the approver's data scope: business-wide approvers can act for any
    # employee; restricted approvers are limited to their managed hierarchy.
    requestable_employees.find_by(id: id)
  end

  def managed_employees_for_form
    return [] unless current_user.can?(:approve_requests)
    requestable_employees.where(active: true).order(:first_name, :last_name)
  end

  # Employees this user may submit requests on behalf of. Resolves scope
  # most-specific-first (approve_requests → view_requests → view_employees) so a
  # business-wide approver can act for everyone; falls back to the hierarchy.
  def requestable_employees
    EmployeeScope.new(current_user)
                 .for_permissions(:approve_requests, :view_requests, :view_employees)
  end

  PUNCH_CHECK_IN_LOOKBACK = 62.days

  # Recent check-ins as { "YYYY-MM-DD" work date => business-local "YYYY-MM-DDTHH:MM" },
  # for the request form's live check-out ordering hint (punch_order_guard).
  # EmployeeRequest validates server-side; this is display only.
  def punch_check_ins_for(target_user)
    tz = target_user.business.timezone_object
    AttendanceRecord.where(user: target_user, work_date: (Date.current - PUNCH_CHECK_IN_LOOKBACK)..)
                    .where.not(check_in_at: nil)
                    .pluck(:work_date, :check_in_at)
                    .to_h { |date, at| [ date.iso8601, at.in_time_zone(tz).strftime("%Y-%m-%dT%H:%M") ] }
  end

  def allowed_request_types_for(target_user)
    assignment = ShiftAssignment.current.find_by(user: target_user)
    types = if assignment&.shift&.hour_based?
      EmployeeRequest::REQUEST_TYPES.reject { |t| t == "late_permission" }
    else
      EmployeeRequest::REQUEST_TYPES
    end
    # Not offered on behalf of an employee the actor may not file a salary
    # advance for (EmployeeRequestPolicy#create? — enforced there on submit).
    # A standalone probe (user_id), never built into target_user's requests.
    advance = EmployeeRequest.new(user_id: target_user.id, request_type: "salary_advance")
    types -= [ "salary_advance" ] unless policy(advance).create?
    types
  end

  def permission_limits_for(target_user)
    shift       = ShiftAssignment.current.find_by(user: target_user)&.shift
    biz         = target_user.business
    month_start = Date.current.beginning_of_month
    month_end   = Date.current.end_of_month

    %w[late_permission early_leave].each_with_object({}) do |type, h|
      limit = if type == "late_permission"
                shift&.max_late_permission_minutes || biz.max_late_permission_minutes
              else
                shift&.max_early_leave_permission_minutes || biz.max_early_leave_permission_minutes
              end
      next unless limit

      used = EmployeeRequest
               .where(user: target_user, request_type: type, status: %w[pending approved])
               .where(requested_for_date: month_start..month_end)
               .sum(:duration_minutes)
      h[type] = { limit: limit, used: used, remaining: [ limit - used, 0 ].max }
    end
  end

  def request_params
    params.require(:employee_request)
          .permit(:request_type, :requested_for_date, :reason, :amount, :duration_minutes,
                  :correction_type, :proposed_time, :proposed_date)
  end

  def prefill_from_params(request)
    if params[:request_type].in?(EmployeeRequest::REQUEST_TYPES)
      request.request_type = params[:request_type]
    end
    if params[:requested_for_date].present?
      request.requested_for_date = params[:requested_for_date]
    end
    if params[:correction_type].in?(EmployeeRequest::CORRECTION_TYPES)
      request.correction_type = params[:correction_type]
    end
    if params[:proposed_time].present?
      request.proposed_time = params[:proposed_time]
    end
    if params[:proposed_date].present?
      request.proposed_date = params[:proposed_date]
    end
  end

  def salary_advances_csv
    require "csv"
    # Export only approved advances awaiting disbursement (all pages, not just current).
    advances = @csv_requests.select { |r| r.salary_advance? && r.approved? }
    CSV.generate(headers: true) do |csv|
      csv << [ "Employee Name", "Phone Number", "Identity Card Number",
               "Amount (#{current_user.business.currency})", "Request Date", "Approved By Manager", "Status" ]
      advances.each do |req|
        csv << [
          req.user.full_name,
          req.user.phone_number,
          req.user.identity_card_number,
          req.amount,
          req.requested_for_date.strftime("%Y-%m-%d"),
          req.reviewed_by&.full_name,
          req.status.humanize
        ]
      end
    end
  end
end
