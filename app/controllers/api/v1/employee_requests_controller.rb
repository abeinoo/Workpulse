module Api
  module V1
    class EmployeeRequestsController < BaseController
      before_action :set_request, only: [ :show, :approve, :reject ]

      def index
        authorize EmployeeRequest
        requests = policy_scope(EmployeeRequest)
                     .includes(:user, :reviewed_by)
                     .order(created_at: :desc)
        render_success(requests.map { |r| request_json(r) })
      end

      def show
        authorize @request
        render_success(request_json(@request))
      end

      def create
        req = current_user.employee_requests.new(request_params)
        authorize req

        if req.save
          render_success(request_json(req), status: :created)
        else
          render_error("Failed to submit request", errors: req.errors.full_messages)
        end
      end

      def approve
        authorize @request, :approve?
        result = Requests::Approver.approve(
          request:       @request,
          reviewed_by:   current_user,
          response_note: params[:response_note]
        )
        handle_result(result)
      end

      def reject
        authorize @request, :reject?
        result = Requests::Approver.reject(
          request:       @request,
          reviewed_by:   current_user,
          response_note: params[:response_note]
        )
        handle_result(result)
      end

      private

      def set_request
        @request = policy_scope(EmployeeRequest).find(params[:id])
      end

      def request_params
        params.require(:employee_request)
              .permit(:request_type, :requested_for_date, :amount, :reason, :duration_minutes)
      end

      def handle_result(result)
        if result.success?
          render_success(request_json(result.request))
        else
          render_error(result.error)
        end
      end

      def request_json(req)
        req.slice(
          :id, :request_type, :status,
          :requested_for_date, :amount, :reason,
          :response_note, :affects_payroll,
          :reviewed_at, :created_at
        ).merge(
          user_id:        req.user_id,
          reviewed_by_id: req.reviewed_by_id
        )
      end
    end
  end
end
