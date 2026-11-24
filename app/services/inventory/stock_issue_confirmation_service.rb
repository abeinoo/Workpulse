module Inventory
  # The single entry point to confirm (physically issue) an approved stock
  # issue: posts its stock movements via the existing Inventory::StockIssuePoster
  # — never duplicated here. Approval already happened
  # (Inventory::StockIssueApproval#approve!); confirmation only requires that
  # the issue has already been approved, and is the ONLY point at which
  # inventory is actually deducted.
  #
  # Enforced here: confirm_stock_issues (or the trusted Quick Issue context)
  # and access to the issue's warehouse — checked first, and again under the
  # lock together with the warehouse's active status. The approver may confirm what they approved.
  #
  # Idempotency / concurrency: the issue row is locked for the duration of the
  # transaction (with_lock), so two concurrent "Confirm Issue" submissions for
  # the same issue serialize — the second sees status != "approved" once the
  # first commits and is refused as already processed. A double click, a
  # browser refresh, or a client retry can never post two movements for the
  # same issue.
  #
  # Confirmation consumes the reservation approval made (see
  # Inventory::StockAvailability): the poster locks the products and re-checks
  # that the quantities are still available to THIS issue — on-hand minus
  # other approved issues' reservations — since a count, adjustment or
  # transfer can shrink on-hand after approval. If not, the whole transaction
  # fails and the issue is left exactly as it was — "approved" (reservation
  # intact), never "issued". In the Quick Issue context the "confirm" audit
  # entry is mandatory (log_audit!).
  class StockIssueConfirmationService
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
      @issue = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)
      unless StockIssueAuthorization.step_permitted?(@actor, :confirm, context: @context)
        return Result.new(ok: false, issue: @issue, error: StockIssueAuthorization.message)
      end
      unless WarehouseReach.permits?(@actor, @issue.warehouse_id) # service-level reach (Phase 2)
        return Result.new(ok: false, issue: @issue, error: WarehouseReach.message)
      end

      @issue.with_lock do
        return already_processed_error if @issue.voided?
        return not_approved_error unless @issue.approved?

        # The issue's ORIGINAL warehouse, re-verified under the issue lock
        # (warehouse row FOR SHARE): active, and still reached by the actor.
        # Stock is deducted from exactly this warehouse — never re-resolved,
        # never another one. The same check serves the Quick Issue's step.
        warehouse_error = IssueWarehouseReach.for(@actor).verify_under_lock(@issue)
        return Result.new(ok: false, issue: @issue, error: warehouse_error) if warehouse_error

        poster_result = Inventory::StockIssuePoster.new(@issue).call
        raise ActiveRecord::RecordInvalid, @issue unless poster_result.ok?

        @issue.issued_at = Time.current
        @issue.issued_by = @actor
        @issue.save!

        audit = { actor: @actor, auditable: @issue, action: "confirm", changes: { status: %w[approved issued] } }
        @context ? log_audit!(**audit) : log_audit(**audit)
      end

      Result.new(ok: true, issue: @issue)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, issue: @issue, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def already_processed_error
      Result.new(ok: false, issue: @issue,
                error: I18n.t("inventory.stock_issues.errors.already_processed"))
    end

    def not_approved_error
      Result.new(ok: false, issue: @issue,
                error: I18n.t("inventory.stock_issues.errors.not_approved"))
    end
  end
end
