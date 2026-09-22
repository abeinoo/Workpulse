module Inventory
  # Saves a draft stock issue — used by both the create and update controller
  # actions — and logs the "create"/"update" audit entry. Never touches stock;
  # that only happens at confirmation (Inventory::StockIssueConfirmationService).
  class StockIssueDraftService
    include AuditLoggable

    Result = Struct.new(:ok, :issue, keyword_init: true) do
      def ok? = ok
    end

    def initialize(issue, actor:)
      @issue = issue
      @actor = actor
    end

    def call
      new_record = @issue.new_record?

      if @issue.save
        log_audit(actor: @actor, auditable: @issue, action: new_record ? "create" : "update")
        Result.new(ok: true, issue: @issue)
      else
        Result.new(ok: false, issue: @issue)
      end
    end
  end
end
