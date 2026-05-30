module Notifications
  # Builds the right in-app notification for each EmployeeRequest lifecycle
  # transition, picking the event_type/category from the request type:
  #   - punch_correction → attendance_correction_* (attendance category)
  #   - everything else  → employee_request_*       (approvals category)
  #
  # All copy is i18n-driven so future channels reuse the same strings.
  class RequestNotifier
    def self.approved(request:, actor:) = new(request, actor).notify(:approved)
    def self.rejected(request:, actor:) = new(request, actor).notify(:rejected)
    def self.submitted(request:)        = new(request, nil).notify_managers

    def initialize(request, actor)
      @request = request
      @actor   = actor
    end

    # Notify the employee that their request was approved/rejected.
    def notify(outcome)
      Notifications::Creator.call(
        user:       @request.user,
        event_type: event_type_for(outcome),
        notifiable: @request,
        title:      I18n.t("notifications.requests.#{message_key(outcome)}.title",
                           type: request_type_label, default: default_title(outcome)),
        body:       I18n.t("notifications.requests.#{message_key(outcome)}.body",
                           type: request_type_label, date: request_date, default: ""),
        data:       { request_type: @request.request_type, outcome: outcome.to_s }
      )
    end

    # Notify reviewers (managers of the requester) that a new request awaits them.
    def notify_managers
      event = @request.punch_correction? ? "manager_pending_corrections" : "manager_pending_approvals"
      Notifications::Creator.broadcast(
        users:      reviewers,
        event_type: event,
        notifiable: @request,
        title:      I18n.t("notifications.requests.manager_pending.title",
                           type: request_type_label, name: @request.user.full_name,
                           default: "New request awaiting review"),
        body:       I18n.t("notifications.requests.manager_pending.body",
                           type: request_type_label, name: @request.user.full_name, default: ""),
        data:       { request_type: @request.request_type, requester_id: @request.user_id },
        dedup_within: 6.hours
      )
    end

    private

    def event_type_for(outcome)
      if @request.punch_correction?
        outcome == :approved ? "attendance_correction_approved" : "attendance_correction_rejected"
      elsif leave_like?
        outcome == :approved ? "leave_approved" : "leave_rejected"
      else
        outcome == :approved ? "employee_request_approved" : "employee_request_rejected"
      end
    end

    # late_permission / early_leave behave like leave requests for notification
    # categorisation; salary_advance stays in the generic approvals bucket.
    def leave_like?
      @request.respond_to?(:late_permission?) &&
        (@request.late_permission? || @request.early_leave?)
    end

    def message_key(outcome)
      if @request.punch_correction?
        outcome == :approved ? "correction_approved" : "correction_rejected"
      elsif leave_like?
        outcome == :approved ? "leave_approved" : "leave_rejected"
      else
        outcome == :approved ? "approved" : "rejected"
      end
    end

    # Who can review this requester's requests: their direct manager plus the
    # managers of the branches they belong to — limited to users who actually
    # hold the approve_requests permission. De-duplicated, requester excluded.
    def reviewers
      requester = @request.user
      branch_ids = requester.branch_ids
      candidate_ids = []
      candidate_ids << requester.manager_id if requester.manager_id
      candidate_ids.concat(Branch.where(id: branch_ids).pluck(:branch_manager_id, :area_manager_id).flatten)
      candidate_ids = candidate_ids.compact.uniq - [ requester.id ]
      return [] if candidate_ids.empty?

      User.where(id: candidate_ids, active: true)
          .select { |u| u.can?(:approve_requests) }
    end

    def request_type_label
      I18n.t("requests.types.#{@request.request_type}", default: @request.request_type.to_s.humanize)
    end

    def request_date
      @request.respond_to?(:requested_for_date) && @request.requested_for_date ?
        I18n.l(@request.requested_for_date, format: :short) : ""
    end

    def default_title(outcome)
      "#{request_type_label} #{outcome}"
    end
  end
end
