module Inventory
  # Saves a NEW draft stock issue and logs its "create" audit entry. Never
  # touches stock; that only happens at confirmation
  # (Inventory::StockIssueConfirmationService). Edits go through
  # Inventory::StockIssueEditor.
  #
  # Enforced here, whoever the caller (Stock Issue & Quick Issue
  # authorization): create_stock_issues (or the trusted Quick Issue context —
  # see Inventory::StockIssueAuthorization.step_permitted?) AND the warehouse:
  # an active warehouse of the actor's business that the actor is authorized
  # to use (Inventory::IssueWarehouseReach). The warehouse id comes from the
  # caller and is never trusted — it is re-checked here. In the Quick Issue
  # context the "create" audit entry is mandatory (log_audit!): if it cannot
  # be written, AuditLoggable::AuditWriteFailed propagates and the Quick
  # Issue's transaction rolls back.
  class StockIssueDraftService
    include AuditLoggable

    Result = Struct.new(:ok, :issue, keyword_init: true) do
      def ok? = ok
    end

    def initialize(issue, actor:, context: nil, audit_metadata: {})
      @issue          = issue
      @actor          = actor
      @context        = context
      @audit_metadata = audit_metadata
    end

    def call
      new_record = @issue.new_record?
      return refuse(StockIssueAuthorization.message) unless StockIssueAuthorization.step_permitted?(@actor, :create, context: @context)

      reach = IssueWarehouseReach.for(@actor)
      return refuse(reach.message) unless reach.issuable?(@issue.warehouse_id)

      @issue.warehouse_source = "selected" if new_record
      @issue.assign_cost_attribution_branch
      return Result.new(ok: false, issue: @issue) unless @issue.save

      audit = { actor: @actor, auditable: @issue, action: new_record ? "create" : "update", metadata: @audit_metadata }
      @context ? log_audit!(**audit) : log_audit(**audit)
      Result.new(ok: true, issue: @issue)
    end

    private

    def refuse(message)
      @issue.errors.add(:base, message)
      Result.new(ok: false, issue: @issue)
    end
  end
end
