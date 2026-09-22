module Inventory
  # Cancels a stock issue before it's physically issued: draft -> cancelled or
  # approved -> cancelled. Neither state has posted any inventory movement yet
  # (that only happens at StockIssueConfirmationService#call), so cancellation
  # never touches stock and needs no reversal — it's a pure status change.
  #
  # Once "issued", an issue can never be cancelled — only voided (which
  # reverses the real posted movements via Inventory::DocumentVoider).
  class StockIssueCancellation
    include AuditLoggable

    Result = Struct.new(:ok, :issue, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(stock_issue_id:, actor:, reason:)
      @stock_issue_id = stock_issue_id
      @actor          = actor
      @reason         = reason.to_s.strip
    end

    def call
      issue = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)

      unless %w[draft approved].include?(issue.status)
        return Result.new(ok: false, issue: issue,
                          error: I18n.t("inventory.stock_issues.errors.invalid_transition"))
      end

      if @reason.blank?
        issue.errors.add(:cancellation_reason, :blank)
        return Result.new(ok: false, issue: issue, error: issue.errors.full_messages.to_sentence)
      end

      from_status = issue.status
      ActiveRecord::Base.transaction do
        issue.status              = :cancelled
        issue.cancelled_by        = @actor
        issue.cancelled_at        = Time.current
        issue.cancellation_reason = @reason
        issue.save!
        log_audit(actor: @actor, auditable: issue, action: "cancel",
                  changes: { status: [ from_status, "cancelled" ] }, metadata: { reason: @reason })
      end

      Result.new(ok: true, issue: issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: issue, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
