module Requests
  # Transitions an EmployeeRequest through its lifecycle.
  #
  # approve — pending → approved (all request types).
  #           For salary advances this records manager approval only; no Advance
  #           is created until an accountant/admin calls pay.
  # reject  — pending → rejected
  # pay     — approved → paid (salary advances only).
  #           Creates the Advance record so the amount is deducted in the next
  #           payroll generation run.
  class Approver
    Result = Struct.new(:success, :request, :error, keyword_init: true) do
      def success? = success
    end

    def self.approve(request:, reviewed_by:, response_note: nil)
      new(request: request, reviewed_by: reviewed_by, response_note: response_note).approve
    end

    def self.reject(request:, reviewed_by:, response_note: nil)
      new(request: request, reviewed_by: reviewed_by, response_note: response_note).reject
    end

    def self.pay(request:, paid_by:)
      new(request: request, reviewed_by: paid_by).pay
    end

    # Marks every approved salary advance in `requests` as paid in one
    # transaction. Returns a struct with paid_count and any per-request errors.
    BulkResult = Struct.new(:paid_count, :errors, keyword_init: true)

    def self.pay_all(requests:, paid_by:)
      paid  = 0
      errs  = []

      ActiveRecord::Base.transaction do
        requests.each do |req|
          result = new(request: req, reviewed_by: paid_by).pay
          if result.success?
            paid += 1
          else
            errs << "#{req.user.full_name}: #{result.error}"
          end
        end
        raise ActiveRecord::Rollback if errs.any?
      end

      BulkResult.new(paid_count: paid, errors: errs)
    end

    def initialize(request:, reviewed_by:, response_note: nil)
      @request       = request
      @reviewed_by   = reviewed_by
      @response_note = response_note
    end

    def approve
      return err("Request is already #{@request.status}") unless @request.pending?

      @request.update!(
        status:        "approved",
        reviewed_by:   @reviewed_by,
        reviewed_at:   Time.current,
        response_note: @response_note
      )

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    def reject
      return err("Request is already #{@request.status}") unless @request.pending?

      @request.update!(
        status:        "rejected",
        reviewed_by:   @reviewed_by,
        reviewed_at:   Time.current,
        response_note: @response_note
      )

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    def pay
      return err("Only approved salary advance requests can be marked as paid") unless payable?

      ActiveRecord::Base.transaction do
        @request.update!(status: "paid", reviewed_by: @reviewed_by, reviewed_at: Time.current)
        Advance.create!(
          user:             @request.user,
          employee_request: @request,
          total_amount:     @request.amount,
          remaining_amount: @request.amount,
          status:           "active",
          issued_at:        Time.current
        )
      end

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    private

    def payable?
      @request.salary_advance? && @request.approved? && @request.advance.nil?
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
