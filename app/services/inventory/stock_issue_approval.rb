module Inventory
  # Handles the stock issue approval decision: pending_approval -> approved |
  # rejected. It NEVER posts inventory movements and NEVER deducts stock —
  # that only happens at Inventory::StockIssueConfirmationService#call
  # ("Confirm Issue").
  #
  # Approval RESERVES the issue's quantities (see Inventory::StockAvailability):
  # it's refused, all-or-nothing, unless every product is available in the
  # warehouse after what other approved issues already hold. The issue row
  # is locked and its status re-checked inside the transaction, and the
  # products are locked before availability is read, so two concurrent
  # approvals can't both take the same last unit and a repeated approve
  # request can't run twice. Rejection happens only from pending_approval,
  # which never holds a reservation, so it has nothing to release.
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

      # Metadata is built after the lock (lazily), from the lines actually approved.
      transition(to: "approved", action: "approve", metadata: -> { { reserved: reserved_quantities } }) do
        StockAvailability.lock_products!(issue.items.map(&:product_id))
        next issue.errors.full_messages.to_sentence unless StockAvailability.validate!(issue)

        issue.approved_by = @actor
        issue.approved_at = Time.current
        nil
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
        nil
      end
    end

    private

    def issue
      @issue ||= StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)
    end

    # { product_id => quantity } this approval reserves — recorded on the audit
    # entry so the allocation is traceable. Editing a pending (or approved)
    # issue returns it to draft under this same row lock
    # (Inventory::StockIssueEditor), so once the lock is held and the status
    # re-checked, the lines are final.
    def reserved_quantities
      issue.items.group_by(&:product_id).transform_values { |items| items.sum { |i| i.quantity.to_d }.to_s }
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

    # The block runs under the issue's row lock with the status already
    # re-verified; it returns nil to proceed or an error message to abort the
    # whole transition (nothing is written).
    def transition(to:, action:, metadata: {})
      return invalid_transition_error unless issue.pending_approval?

      error = nil
      ActiveRecord::Base.transaction do
        issue.lock!
        issue.items.reset # never approve lines loaded before the lock
        unless issue.pending_approval?
          error = I18n.t("inventory.stock_issues.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end
        # Re-checked under the lock: an edit + resubmission
        # (Inventory::StockIssueEditor) may have changed the submitter since
        # the pre-check in #approve!/#reject!.
        if self_approval?
          error = Approvals::SelfApproval.error_message
          raise ActiveRecord::Rollback
        end

        from_status = issue.status
        error = yield
        raise ActiveRecord::Rollback if error

        issue.status = to
        issue.save!
        log_audit(actor: @actor, auditable: issue, action: action,
                  changes: { status: [ from_status, to ] },
                  metadata: metadata.respond_to?(:call) ? metadata.call : metadata)
      end
      return Result.new(ok: false, issue: issue, error: error) if error

      Result.new(ok: true, issue: issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: issue, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
