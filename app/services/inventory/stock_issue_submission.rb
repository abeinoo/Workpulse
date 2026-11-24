module Inventory
  # draft -> pending_approval. The single entry point for submitting a stock
  # issue for approval — never touches stock.
  #
  # Enforced here: create_stock_issues (submission is part of creating; or the
  # trusted Quick Issue context) and the actor's access to the issue's
  # warehouse (Inventory::WarehouseReach), re-read from the stored issue. In the Quick Issue
  # context the "submit_for_approval" audit entry is mandatory (log_audit!).
  class StockIssueSubmission
    include AuditLoggable

    Result = Struct.new(:ok, :issue, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(stock_issue_id:, actor:, context: nil)
      @stock_issue_id = stock_issue_id
      @actor          = actor
      @context        = context
    end

    def call
      issue = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)
      unless StockIssueAuthorization.step_permitted?(@actor, :create, context: @context)
        return Result.new(ok: false, issue: issue, error: StockIssueAuthorization.message)
      end
      unless WarehouseReach.permits?(@actor, issue.warehouse_id) # service-level reach (Phase 2)
        return Result.new(ok: false, issue: issue, error: WarehouseReach.message)
      end
      unless issue.draft?
        return Result.new(ok: false, issue: issue,
                          error: I18n.t("inventory.stock_issues.errors.invalid_transition"))
      end
      # The warehouse must still be active (StockIssue's requires_active_warehouse
      # refuses the transition otherwise); reach was checked above.
      from_status = issue.status
      ActiveRecord::Base.transaction do
        issue.status       = :pending_approval
        issue.submitted_by = @actor
        issue.submitted_at = Time.current
        issue.save!
        audit = { actor: @actor, auditable: issue, action: "submit_for_approval",
                  changes: { status: [ from_status, "pending_approval" ] } }
        @context ? log_audit!(**audit) : log_audit(**audit)
      end

      Result.new(ok: true, issue: issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: issue, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
