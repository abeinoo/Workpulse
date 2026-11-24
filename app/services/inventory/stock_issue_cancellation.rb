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
  #
  # Enforced here: cancel_stock_issues (the creator may cancel if they hold
  # it) and warehouse reach. A reason is required, and the "cancel" audit
  # entry is mandatory (log_audit!): if it cannot be written, the
  # cancellation rolls back and the issue stays as it was.
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
      unless StockIssueAuthorization.permits?(@actor, :cancel)
        return Result.new(ok: false, issue: issue, error: StockIssueAuthorization.message)
      end
      unless WarehouseReach.permits?(@actor, issue.warehouse_id) # service-level reach (Phase 2)
        return Result.new(ok: false, issue: issue, error: WarehouseReach.message)
      end

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
        log_audit!(actor: @actor, auditable: issue, action: "cancel",
                   changes: { status: [ from_status, "cancelled" ] },
                   metadata: { reason: @reason, reservation_released: from_status == "approved" })
      end

      Result.new(ok: true, issue: issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: issue, error: e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      issue&.reload
      Result.new(ok: false, issue: issue, error: I18n.t("inventory.stock_issues.errors.audit_failed"))
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
