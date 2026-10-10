module Inventory
  # The single entry point to confirm (physically issue) an approved stock
  # issue: posts its stock movements via the existing Inventory::StockIssuePoster
  # — never duplicated here. Approval already happened
  # (Inventory::StockIssueApproval#approve!); confirmation only requires that
  # the issue has already been approved, and is the ONLY point at which
  # inventory is actually deducted.
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
  # intact), never "issued".
  class StockIssueConfirmationService
    include AuditLoggable

    Result = Struct.new(:ok, :issue, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(stock_issue_id:, actor:)
      @stock_issue_id = stock_issue_id
      @actor          = actor
    end

    def call
      @issue = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)

      @issue.with_lock do
        return already_processed_error if @issue.voided?
        return not_approved_error unless @issue.approved?

        poster_result = Inventory::StockIssuePoster.new(@issue).call
        raise ActiveRecord::RecordInvalid, @issue unless poster_result.ok?

        @issue.issued_at = Time.current
        @issue.issued_by = @actor
        @issue.save!

        log_audit(actor: @actor, auditable: @issue, action: "confirm",
                  changes: { status: %w[approved issued] })
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
