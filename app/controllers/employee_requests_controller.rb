class EmployeeRequestsController < ApplicationController
  before_action :authenticate_user!

  def index
    # Expose filter params to the view (filter_params is private and not visible there).
    @filters = filter_params

    # All filtering and sorting happens in the database; the view never loads or
    # sifts the full request set in Ruby.
    @requests = policy_scope(EmployeeRequest)
                  .includes(:user, :advance)
                  .with_status(@filters[:status])
                  .for_user(@filters[:user_id])
                  .then { |s| @filters[:branch_id].present? ? s.for_branch(@filters[:branch_id]) : s }
                  .requested_on_or_after(parsed_date(@filters[:date_from]))
                  .requested_on_or_before(parsed_date(@filters[:date_to]))
                  .sorted_for_review

    # Filter-bar option sources, scoped to what this user may see.
    @filter_employees = requestable_employees.active.order(:first_name, :last_name)
    @filter_branches  = Branch.for_business(current_user.business).active.order(:name)
    @active_filters   = @filters.values.any?(&:present?)

    respond_to do |format|
      format.html
      format.csv do
        authorize EmployeeRequest, :index?
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
    @advance_limit         = Salary::AdvanceEligibilityCalculator.for(user: target_user)
  end

  def create
    @request      = EmployeeRequest.new(request_params)
    @request.user = resolve_for_user || current_user

    authorize @request

    if @request.save
      redirect_to employee_requests_path, notice: t("flash.request_submitted")
    else
      @for_user              = @request.user unless @request.user == current_user
      @managed_employees     = managed_employees_for_form
      @permission_limits     = permission_limits_for(@request.user)
      @allowed_request_types = allowed_request_types_for(@request.user)
      @advance_limit         = Salary::AdvanceEligibilityCalculator.for(user: @request.user)
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
      approved_time: params[:approved_time]
    )

    if result.success?
      redirect_back fallback_location: employee_request_path(@request), notice: t("flash.request_approved")
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
    params.permit(:status, :user_id, :branch_id, :date_from, :date_to)
  end

  def parsed_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError
    nil
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

  def allowed_request_types_for(target_user)
    assignment = ShiftAssignment.current.find_by(user: target_user)
    if assignment&.shift&.hour_based?
      EmployeeRequest::REQUEST_TYPES.reject { |t| t == "late_permission" }
    else
      EmployeeRequest::REQUEST_TYPES
    end
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
    # Export only approved advances awaiting disbursement.
    advances = @requests.select { |r| r.salary_advance? && r.approved? }
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
