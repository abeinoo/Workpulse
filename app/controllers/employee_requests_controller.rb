class EmployeeRequestsController < ApplicationController
  before_action :authenticate_user!

  def index
    @requests = policy_scope(EmployeeRequest)
                  .includes(:user)
                  .order(created_at: :desc)

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
  end

  def new
    @for_user          = resolve_for_user
    @request           = EmployeeRequest.new
    authorize @request
    @managed_employees = managed_employees_for_form
  end

  def create
    @request      = EmployeeRequest.new(request_params)
    @request.user = resolve_for_user || current_user

    authorize @request

    if @request.save
      redirect_to employee_requests_path, notice: t("flash.request_submitted")
    else
      @for_user          = @request.user unless @request.user == current_user
      @managed_employees = managed_employees_for_form
      render :new, status: :unprocessable_entity
    end
  end

  def approve
    @request = policy_scope(EmployeeRequest).find(params[:id])
    authorize @request

    result = Requests::Approver.approve(
      request:       @request,
      reviewed_by:   current_user,
      response_note: params[:response_note]
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
                  alert: "Some advances could not be processed: #{result.errors.join("; ")}"
    end
  end

  private

  def resolve_for_user
    return nil unless current_user.branch_manager?
    id = params[:for_user_id].presence || params.dig(:employee_request, :for_user_id).presence
    return nil unless id
    current_user.managed_employees.find_by(id: id)
  end

  def managed_employees_for_form
    return [] unless current_user.branch_manager?
    current_user.managed_employees.where(active: true).order(:first_name, :last_name)
  end

  def request_params
    params.require(:employee_request)
          .permit(:request_type, :requested_for_date, :reason, :amount)
  end

  def salary_advances_csv
    require "csv"
    # Export only approved advances awaiting disbursement.
    advances = @requests.select { |r| r.salary_advance? && r.approved? }
    CSV.generate(headers: true) do |csv|
      csv << [ "Employee Name", "Phone Number", "Identity Card Number",
               "Amount (SAR)", "Request Date", "Approved By Manager", "Status" ]
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
