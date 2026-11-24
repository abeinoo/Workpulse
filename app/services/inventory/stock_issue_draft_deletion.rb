module Inventory
  # Deletes a DRAFT stock issue — part of create_stock_issues. Only a draft
  # (never submitted, nothing reserved, nothing posted) may be deleted; every
  # other state is cancelled (StockIssueCancellation) or voided
  # (DocumentVoider). No reason and no additional audit entry (owner
  # decision); the issue's own earlier audit entries are kept.
  #
  # Enforced here: create_stock_issues, warehouse reach, draft state under the
  # row lock, and ImmutableDocument's guard (StockIssue#destroyable_as_draft?).
  class StockIssueDraftDeletion
    Result = Struct.new(:ok, :issue, :error, keyword_init: true) do
      def ok? = ok
    end

    def initialize(stock_issue_id:, actor:)
      @stock_issue_id = stock_issue_id
      @actor          = actor
    end

    def call
      issue = StockIssue.where(business_id: @actor.business_id).find(@stock_issue_id)
      return failure(issue, StockIssueAuthorization.message) unless StockIssueAuthorization.permits?(@actor, :create)
      return failure(issue, WarehouseReach.message) unless WarehouseReach.permits?(@actor, issue.warehouse_id)

      issue.with_lock do
        return failure(issue, I18n.t("inventory.stock_issues.errors.cannot_delete")) unless issue.draft? && !issue.voided?

        issue.destroy!
      end
      Result.new(ok: true, issue: issue)
    rescue ImmutableDocument::DeletionNotAllowedError, ActiveRecord::RecordNotDestroyed
      failure(issue, I18n.t("inventory.stock_issues.errors.cannot_delete"))
    end

    private

    def failure(issue, error) = Result.new(ok: false, issue: issue, error: error)
  end
end
