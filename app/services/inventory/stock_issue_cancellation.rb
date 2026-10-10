module Inventory
  # Cancels a stock issue before it's physically issued: draft -> cancelled or
  # approved -> cancelled. Neither state has posted any inventory movement yet
  # (that only happens at StockIssueConfirmationService#call), so cancellation
  # never touches stock and needs no reversal — it's a pure status change.
  # Cancelling an approved issue releases its reservation by that same status
  # change (see Inventory::StockAvailability). The row is locked and the
  # status re-checked inside the transaction, so a repeated request — or a
  # cancel racing a confirmation — can't release twice or cancel an issue
  # that has just been issued.
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

      return invalid_transition_error(issue) unless cancellable?(issue)

      if @reason.blank?
        issue.errors.add(:cancellation_reason, :blank)
        return Result.new(ok: false, issue: issue, error: issue.errors.full_messages.to_sentence)
      end

      issue.with_lock do
        return invalid_transition_error(issue) unless cancellable?(issue)

        from_status = issue.status
        issue.status              = :cancelled
        issue.cancelled_by        = @actor
        issue.cancelled_at        = Time.current
        issue.cancellation_reason = @reason
        issue.save!
        log_audit(actor: @actor, auditable: issue, action: "cancel",
                  changes: { status: [ from_status, "cancelled" ] },
                  metadata: { reason: @reason, reservation_released: from_status == "approved" })
      end

      Result.new(ok: true, issue: issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: issue, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def cancellable?(issue)
      !issue.voided? && %w[draft approved].include?(issue.status)
    end

    def invalid_transition_error(issue)
      Result.new(ok: false, issue: issue, error: I18n.t("inventory.stock_issues.errors.invalid_transition"))
    end
  end
end
