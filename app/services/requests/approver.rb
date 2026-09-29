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

    # confirm_out_of_window — the reviewer explicitly acknowledged that a punch
    # correction falls outside the expected attendance window or produces an
    # abnormal worked duration. Required (server-side) for such corrections.
    # approved_at — the reviewer's final punch for a punch correction as ONE
    # datetime ("YYYY-MM-DDTHH:MM" from a datetime-local input, or a Time).
    # approved_time — shorthand used when only a time is given: that time on
    # the proposed date. Blank → the employee's proposal.
    def self.approve(request:, reviewed_by:, response_note: nil, approved_time: nil,
                     approved_at: nil, confirm_out_of_window: false)
      new(request: request, reviewed_by: reviewed_by, response_note: response_note,
          approved_time: approved_time, approved_at: approved_at,
          confirm_out_of_window: confirm_out_of_window).approve
    end

    DATETIME_LOCAL = /\A(\d{4}-\d{2}-\d{2})[T ](\d{2}):(\d{2})/

    # A reviewer datetime ("YYYY-MM-DDTHH:MM" from a datetime-local input, or a
    # Time) as [business-timezone date, "HH:MM"] — the parts
    # PunchCorrectionApplier builds the moment from. nil when blank, :invalid
    # when unparseable.
    def self.parse_approved_at(value, business:)
      return nil if value.blank?

      unless value.is_a?(String)
        local = value.in_time_zone(business.timezone_object)
        return [ local.to_date, local.strftime("%H:%M") ]
      end

      match = value.strip.match(DATETIME_LOCAL) or return :invalid
      hours, minutes = match[2].to_i, match[3].to_i
      return :invalid if hours > 23 || minutes > 59

      [ Date.iso8601(match[1]), format("%02d:%02d", hours, minutes) ]
    rescue ArgumentError
      :invalid
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

    def initialize(request:, reviewed_by:, response_note: nil, approved_time: nil, paid_at: nil,
                   approved_at: nil, confirm_out_of_window: false)
      @confirm_out_of_window = ActiveModel::Type::Boolean.new.cast(confirm_out_of_window) || false
      @approved_at   = approved_at
      @request       = request
      @reviewed_by   = reviewed_by
      @response_note = response_note
      @approved_time = approved_time
      @paid_at       = paid_at
    end

    def approve
      return err("Request is already #{@request.status}") unless @request.pending?
      return err(Approvals::SelfApproval.error_message) if self_approval?

      @request.punch_correction? ? approve_punch_correction : approve_standard
    end

    def reject
      return err("Request is already #{@request.status}") unless @request.pending?
      return err(Approvals::SelfApproval.error_message) if self_approval?

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

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    def approve_punch_correction
      final = parse_approved_at
      return err(I18n.t("requests.errors.invalid_approved_date")) if final == :invalid

      final_date, final_time = final || [ @request.proposed_punch_date, @approved_time.presence || @request.proposed_time ]

      # Every check runs on the FINAL reviewer-selected datetime.
      assessment = PunchCorrectionAssessment.for(@request, date: final_date, time_str: final_time)
      return err(assessment.punch_order_error) if assessment.punch_order_invalid?
      if assessment.requires_confirmation? && !@confirm_out_of_window
        return err(I18n.t("requests.errors.attendance_window_confirmation_required"))
      end

      applier_error = nil
      applied_record = nil

      ActiveRecord::Base.transaction do
        update_attrs = {
          status:        "approved",
          reviewed_by:   @reviewed_by,
          reviewed_at:   Time.current,
          response_note: @response_note
        }
        # Stored as one datetime: exactly the moment the applier will write.
        update_attrs[:approved_punch_at] = assessment.effective_at
        @request.update!(update_attrs)

        result = Requests::PunchCorrectionApplier.call(request: @request)
        unless result.success?
          applier_error = result.error
          raise ActiveRecord::Rollback
        end
        applied_record = result.record
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
          response_note:   @response_note,
          punch_review:    punch_review_metadata(final_date, final_time),
          attendance_window: assessment.audit_metadata.merge(
            confirmed_by_reviewer:       assessment.requires_confirmation?,
            resulting_worked_minutes:    applied_record&.worked_minutes,
            resulting_duration_severity: applied_record&.duration_severity
          )
        }
      )

      Result.new(success: true, request: @request)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.join(", "))
    end

    def parse_approved_at
      self.class.parse_approved_at(@approved_at, business: @request.user.business)
    end

    # Employee proposal vs reviewer-selected final punch, for the audit trail.
    # The reviewer and the moment are the audit row's actor / created_at, and are
    # repeated here so the entry reads on its own.
    def punch_review_metadata(final_date, final_time)
      proposed_date = @request.proposed_punch_date
      proposed_time = @request.proposed_time
      date_changed  = final_date != proposed_date
      time_changed  = EmployeeRequest.normalized_clock(final_time) != EmployeeRequest.normalized_clock(proposed_time)
      proposed_at = PunchCorrectionApplier.effective_punch_at(request: @request, date: proposed_date,
                                                             time_str: proposed_time)
      {
        proposed_at:   proposed_at&.iso8601,  final_at:      @request.approved_punch_at&.iso8601,
        datetime_changed: date_changed || time_changed,
        proposed_date: proposed_date.iso8601, proposed_time: proposed_time,
        final_date:    final_date.iso8601,    final_time:    final_time,
        date_changed:  date_changed,          time_changed:  time_changed,
        change:        if date_changed && time_changed then "date_and_time"
                       elsif date_changed then "date"
                       elsif time_changed then "time"
                       else "none"
                       end,
        reviewer_id:   @reviewed_by.id,
        reviewer_name: @reviewed_by.full_name,
        reviewed_at:   @request.reviewed_at&.iso8601
      }
    end

    # Backstop for direct service/API calls (the policy already hides the UI):
    # the reviewer may not be the employee who submitted the request.
    def self_approval?
      Approvals::SelfApproval.by_requester?(approver: @reviewed_by, requester: @request.user_id)
    end

    def payable?
      @request.salary_advance? && @request.approved? && @request.advance.nil?
    end

    def err(message)
      Result.new(success: false, error: message)
    end
  end
end
