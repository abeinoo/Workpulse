module Inventory
  # Saves edits to an existing stock issue's header and lines — the update
  # path for a draft, and for a pending_approval or approved issue ("Edit
  # Request"). (New drafts are still created through
  # Inventory::StockIssueDraftService.)
  #
  # Editing a pending_approval or approved issue returns it to draft, in the
  # same transaction as the line changes, with submitted_by/at and
  # approved_by/at cleared — no stale submission or approval survives on the
  # row. It must be resubmitted (Inventory::StockIssueSubmission) and approved
  # again; approval validates availability against the NEW lines under lock
  # (Inventory::StockIssueApproval).
  #
  # Reservations are derived from status (approved = reserved, see
  # Inventory::StockAvailability), so approved -> draft releases the old
  # reservation atomically with this commit — the same mechanism as
  # Inventory::StockIssueCancellation. Releasing only frees stock, so no
  # product lock is needed. No inventory movement is ever written here; stock
  # moves only at Inventory::StockIssueConfirmationService, which requires
  # "approved" under the same row lock and so can never confirm an issue
  # this edit has reopened.
  #
  # Concurrency: the row is locked and its status re-checked before anything
  # is assigned, so an edit can't land on an issue that was just issued,
  # rejected or cancelled, and an approval or confirmation racing this edit
  # sees "draft" and refuses. A stale lock_token (another user saved since the
  # form was opened) is refused instead of silently overwriting newer lines.
  #
  # Audit: "update" with a before/after line snapshot, plus a
  # "reopen_for_editing" entry when the issue was reopened (from
  # pending_approval, or from approved with the revoked approver/time and the
  # released quantities). Earlier submit/approve/reject entries are never
  # touched.
  class StockIssueEditor
    include AuditLoggable

    Result = Struct.new(:ok, :issue, :error, :reopened, :reopened_from, keyword_init: true) do
      def ok? = ok
      def reopened? = reopened
      def approval_revoked? = reopened_from == "approved"
    end

    def initialize(stock_issue_id:, actor:, attributes:, lock_token: nil)
      @stock_issue_id = stock_issue_id
      @actor          = actor
      @attributes     = attributes
      @lock_token     = lock_token.presence
    end

    def call
      @issue   = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)
      reopened    = false
      error       = nil
      from_status = nil

      ActiveRecord::Base.transaction do
        @issue.lock!

        error = precondition_error
        raise ActiveRecord::Rollback if error

        from_status  = @issue.status
        lines_before = line_snapshot
        reopen_audit = reopen_metadata if StockIssue::REOPENED_BY_EDIT_STATUSES.include?(from_status)

        @issue.assign_attributes(@attributes)
        preload_line_products
        if reopen_audit
          @issue.status       = :draft
          @issue.submitted_by = nil
          @issue.submitted_at = nil
          @issue.approved_by  = nil
          @issue.approved_at  = nil
          reopened = true
        end

        unless @issue.save
          restore_reopened_fields(from_status) if reopened
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
                    changes: { status: [ from_status, "draft" ] }, metadata: reopen_audit)
        end
        log_audit(actor: @actor, auditable: @issue, action: "update",
                  changes: { items: [ lines_before, lines_after ] }.reject { |_, (a, b)| a == b })
      end

      Result.new(ok: error.nil?, issue: @issue, error: error, reopened: reopened,
                 reopened_from: (from_status if reopened))
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

    # Line validations read each line's product and whether it's a family
    # (StockIssueItem#product_is_transactable) — load both for all lines in
    # two queries instead of two per line.
    def preload_line_products
      lines = @issue.items.reject(&:marked_for_destruction?)
      ActiveRecord::Associations::Preloader.new(records: lines, associations: { product: :child_products }).call
    end

    # Captured before anything changes: what the reopen invalidates.
    def reopen_metadata
      meta = { previous_submission_invalidated: true,
               previous_submitted_by_id: @issue.submitted_by_id,
               previous_submitted_at: @issue.submitted_at&.iso8601 }
      return meta unless @issue.approved?

      meta.merge(approval_revoked: true,
                 previous_approved_by_id: @issue.approved_by_id,
                 previous_approved_at: @issue.approved_at&.iso8601,
                 reservation_released: @issue.items.group_by(&:product_id)
                                                 .transform_values { |items| items.sum { |i| i.quantity.to_d }.to_s })
    end

    # A failed save leaves the record re-rendered in the edit form; put the
    # in-memory workflow fields back to what is still in the database.
    def restore_reopened_fields(from_status)
      @issue.status = from_status
      %w[submitted_by_id submitted_at approved_by_id approved_at].each do |attr|
        @issue[attr] = @issue.attribute_in_database(attr)
      end
    end

    def line_snapshot(items = @issue.items)
      items.map { |i| { "product_id" => i.product_id, "quantity" => i.quantity.to_d.to_s } }
           .sort_by { |l| [ l["product_id"], l["quantity"] ] }
    end
  end
end
