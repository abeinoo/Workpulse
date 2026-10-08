module Requests
  # Creates an EmployeeRequest and records who submitted it (SEC-P10-1, Pilot 10
  # unblock). The single entry point for creating requests from the web and the
  # API: the submitter is always the acting user, set here — never taken from
  # request params — and the creation is audited in the same transaction.
  #
  #   request.user         — the employee the request is FOR
  #   request.submitted_by — the actor (the employee, or an approver on behalf)
  #
  # Authorization (EmployeeRequestPolicy#create?) stays with the caller.
  # Returns true / false like ActiveRecord#save; validation errors stay on the
  # request.
  class Submitter
    include AuditLoggable

    def self.call(request:, actor:)
      new(request: request, actor: actor).call
    end

    def initialize(request:, actor:)
      @request = request
      @actor   = actor
    end

    def call
      @request.submitted_by = @actor

      ActiveRecord::Base.transaction do
        raise ActiveRecord::Rollback unless @request.save

        log_audit(
          actor:     @actor,
          auditable: @request,
          action:    "create",
          metadata:  {
            request_type:    @request.request_type,
            for_user_id:     @request.user_id,
            submitted_by_id: @request.submitted_by_id,
            on_behalf:       @request.user_id != @request.submitted_by_id
          }
        )
      end

      @request.persisted?
    end
  end
end
