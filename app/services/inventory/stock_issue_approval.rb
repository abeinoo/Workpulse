module Inventory
  # Handles the stock issue approval decision: pending_approval -> approved |
  # rejected. This is purely an authorization decision — it NEVER posts
  # inventory movements and NEVER deducts stock. The approved issue is simply
  # authorized to be physically issued; that only happens at
  # Inventory::StockIssueConfirmationService#call ("Confirm Issue").
  #
  # Self-approval is blocked (the person who submitted the issue may not
  # approve or reject their own submission), with the business-owner
  # exception, via the shared Approvals::SelfApproval rule — mirrors
  # Inventory::GoodsReceiptApproval.
  class StockIssueApproval
    include AuditLoggable

    Result = Struct.new(:ok, :issue, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(stock_issue_id:, actor:)
      @stock_issue_id = stock_issue_id
      @actor          = actor
    end

    # pending_approval -> approved
    def approve!
      return self_approval_error if self_approval?

      transition(to: "approved", action: "approve") do
        issue.approved_by = @actor
        issue.approved_at = Time.current
      end
    end

    # pending_approval -> rejected
    def reject!(reason:)
      return self_approval_error if self_approval?

      reason = reason.to_s.strip
      if reason.blank?
        issue.errors.add(:rejection_reason, :blank)
        return Result.new(ok: false, issue: issue, error: issue.errors.full_messages.to_sentence)
      end

      transition(to: "rejected", action: "reject", metadata: { reason: reason }) do
        issue.rejected_by     = @actor
        issue.rejected_at     = Time.current
        issue.rejection_reason = reason
      end
    end

    private

    def issue
      @issue ||= StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)
    end

    def self_approval?
      return false if @actor.owner?

      Approvals::SelfApproval.by_requester?(approver: @actor, requester: issue.submitted_by_id)
    end

    def self_approval_error
      Result.new(ok: false, issue: issue, error: Approvals::SelfApproval.error_message)
    end

    def invalid_transition_error
      Result.new(ok: false, issue: issue,
                error: I18n.t("inventory.stock_issues.errors.invalid_transition"))
    end

    def transition(to:, action:, metadata: {})
      return invalid_transition_error unless issue.pending_approval?

      from_status = issue.status
      ActiveRecord::Base.transaction do
        issue.status = to
        yield if block_given?
        issue.save!
        log_audit(actor: @actor, auditable: issue, action: action,
                  changes: { status: [ from_status, to ] }, metadata: metadata)
      end
      Result.new(ok: true, issue: issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: issue, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
