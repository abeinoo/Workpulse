module Inventory
  # draft -> pending_approval. The single entry point for submitting a stock
  # issue for approval — never touches stock.
  class StockIssueSubmission
    include AuditLoggable

    Result = Struct.new(:ok, :issue, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(stock_issue_id:, actor:)
      @stock_issue_id = stock_issue_id
      @actor          = actor
    end

    def call
      issue = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)

      unless issue.draft?
        return Result.new(ok: false, issue: issue,
                          error: I18n.t("inventory.stock_issues.errors.invalid_transition"))
      end

      from_status = issue.status
      ActiveRecord::Base.transaction do
        issue.status       = :pending_approval
        issue.submitted_by = @actor
        issue.submitted_at = Time.current
        issue.save!
        log_audit(actor: @actor, auditable: issue, action: "submit_for_approval",
                  changes: { status: [ from_status, "pending_approval" ] })
      end

      Result.new(ok: true, issue: issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: issue, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
