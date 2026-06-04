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
    include AuditLoggable
    Result = Struct.new(:success, :request, :error, keyword_init: true) do
      def success? = success
    end

    def self.approve(request:, reviewed_by:, response_note: nil, approved_time: nil)
      new(request: request, reviewed_by: reviewed_by, response_note: response_note,
          approved_time: approved_time).approve
    end

    def self.reject(request:, reviewed_by:, response_note: nil)
      new(request: request, reviewed_by: reviewed_by, response_note: response_note).reject
    end

    # paid_at — disbursement timestamp recorded on the Advance (defaults to now).
    # note    — optional disbursement note stored on the request.
    def self.pay(request:, paid_by:, paid_at: nil, note: nil)
      new(request: request, reviewed_by: paid_by, response_note: note, paid_at: paid_at).pay
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

    def initialize(request:, reviewed_by:, response_note: nil, approved_time: nil, paid_at: nil)
      @request       = request
      @reviewed_by   = reviewed_by
      @response_note = response_note
      @approved_time = approved_time
      @paid_at       = paid_at
    end

    def approve
      return err("Request is already #{@request.status}") unless @request.pending?

      @request.punch_correction? ? approve_punch_correction : approve_standard
    end

    def reject
      return err("Request is already #{@request.status}") unless @request.pending?

      @request.update!(
        status:        "rejected",
        reviewed_by:   @reviewed_by,
        reviewed_at:   Time.current,
        response_note: @response_note
      )

      log_audit(
        actor:     @reviewed_by,
        auditable: @request,
        action:    "reject",
        changes:   { status: ["pending", "rejected"] },
        metadata:  { request_type: @request.request_type, response_note: @response_note }
      )

      Notifications::RequestNotifier.rejected(request: @request, actor: @reviewed_by)

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    def pay
      return err("Only approved salary advance requests can be marked as paid") unless payable?

      paid_at = @paid_at || Time.current

      ActiveRecord::Base.transaction do
        update_attrs = { status: "paid", reviewed_by: @reviewed_by, reviewed_at: Time.current }
        update_attrs[:response_note] = @response_note if @response_note.present?
        @request.update!(update_attrs)
        Advance.create!(
          user:             @request.user,
          employee_request: @request,
          total_amount:     @request.amount,
          remaining_amount: @request.amount,
          status:           "active",
          issued_at:        paid_at
        )
        log_audit(
          actor:     @reviewed_by,
          auditable: @request,
          action:    "pay",
          changes:   { status: ["approved", "paid"] },
          metadata:  { amount: @request.amount, paid_at: paid_at, note: @response_note }.compact
        )
      end

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    private

    def approve_standard
      @request.update!(
        status:        "approved",
        reviewed_by:   @reviewed_by,
        reviewed_at:   Time.current,
        response_note: @response_note
      )

      Payroll::PermissionApplier.call(@request)

      log_audit(
        actor:     @reviewed_by,
        auditable: @request,
        action:    "approve",
        changes:   { status: ["pending", "approved"] },
        metadata:  { request_type: @request.request_type, response_note: @response_note }
      )

      Notifications::RequestNotifier.approved(request: @request, actor: @reviewed_by)

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    def approve_punch_correction
      applier_error = nil

      ActiveRecord::Base.transaction do
        update_attrs = {
          status:        "approved",
          reviewed_by:   @reviewed_by,
          reviewed_at:   Time.current,
          response_note: @response_note
        }
        update_attrs[:approved_time] = @approved_time if @approved_time.present?
        @request.update!(update_attrs)

        result = Requests::PunchCorrectionApplier.call(request: @request)
        unless result.success?
          applier_error = result.error
          raise ActiveRecord::Rollback
        end
      end

      return err(applier_error) if applier_error

      log_audit(
        actor:     @reviewed_by,
        auditable: @request,
        action:    "approve",
        changes:   { status: ["pending", "approved"] },
        metadata:  {
          request_type:    @request.request_type,
          correction_type: @request.correction_type,
          approved_time:   @request.approved_time,
          proposed_time:   @request.proposed_time,
          response_note:   @response_note
        }
      )

      Notifications::RequestNotifier.approved(request: @request, actor: @reviewed_by)

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    def payable?
      @request.salary_advance? && @request.approved? && @request.advance.nil?
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
