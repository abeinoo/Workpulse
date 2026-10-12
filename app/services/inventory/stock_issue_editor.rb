module Inventory
  # Saves edits to an existing stock issue's header and lines — the update
  # path for both a draft and a pending_approval issue ("Edit Request").
  # (New drafts are still created through Inventory::StockIssueDraftService.)
  #
  # Editing a pending_approval issue withdraws it: pending_approval -> draft,
  # with submitted_by/submitted_at cleared, in the same transaction as the line
  # changes. It must be resubmitted (Inventory::StockIssueSubmission) and
  # approved again; approval validates availability against the NEW lines
  # under lock (Inventory::StockIssueApproval). A pending issue holds no
  # reservation and no movements, so withdrawing it never touches stock.
  #
  # Concurrency: the row is locked and its status re-checked before anything
  # is assigned, so an edit can't land on an issue that was just approved,
  # rejected or cancelled, and an approval racing this edit sees "draft" and
  # refuses. A stale lock_token (another user saved since the form was opened)
  # is refused instead of silently overwriting the newer lines.
  #
  # Audit: "update" with a before/after line snapshot, plus a
  # "reopen_for_editing" entry when a pending issue was withdrawn. Earlier
  # submit/approve/reject entries are never touched.
  class StockIssueEditor
    include AuditLoggable

    Result = Struct.new(:ok, :issue, :error, :reopened, keyword_init: true) do
      def ok? = ok
      def reopened? = reopened
    end

    def initialize(stock_issue_id:, actor:, attributes:, lock_token: nil)
      @stock_issue_id = stock_issue_id
      @actor          = actor
      @attributes     = attributes
      @lock_token     = lock_token.presence
    end

    def call
      @issue   = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)
      reopened = false
      error    = nil

      ActiveRecord::Base.transaction do
        @issue.lock!

        error = precondition_error
        raise ActiveRecord::Rollback if error

        from_status  = @issue.status
        lines_before = line_snapshot

        @issue.assign_attributes(@attributes)
        if @issue.pending_approval?
          @issue.status       = :draft
          @issue.submitted_by = nil
          @issue.submitted_at = nil
          reopened = true
        end

        unless @issue.save
          @issue.status = from_status if reopened
          reopened = false
          error = @issue.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end
        # Item writes touch the parent (StockIssueItem touch: true); this also
        # advances the lock_token on a save that changed nothing.
        @issue.touch

        lines_after = line_snapshot(@issue.items.reload)
        if reopened
          log_audit(actor: @actor, auditable: @issue, action: "reopen_for_editing",
                    changes: { status: [ from_status, "draft" ] },
                    metadata: { previous_submission_invalidated: true })
        end
        log_audit(actor: @actor, auditable: @issue, action: "update",
                  changes: { items: [ lines_before, lines_after ] }.reject { |_, (a, b)| a == b })
      end

      Result.new(ok: error.nil?, issue: @issue, error: error, reopened: reopened)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound => e
      Result.new(ok: false, issue: @issue, error: e.message, reopened: false)
    end

    private

    def precondition_error
      unless StockIssue::EDITABLE_STATUSES.include?(@issue.status) && !@issue.voided?
        return I18n.t("inventory.stock_issues.errors.not_editable")
      end
      return nil if @lock_token.nil? || @lock_token == @issue.lock_token

      I18n.t("inventory.stock_issues.errors.stale_edit")
    end

    def line_snapshot(items = @issue.items)
      items.map { |i| { "product_id" => i.product_id, "quantity" => i.quantity.to_d.to_s } }
           .sort_by { |l| [ l["product_id"], l["quantity"] ] }
    end
  end
end
