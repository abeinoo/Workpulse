module Inventory
  module Imports
    # "Complete Import" — submits the batch's single draft StockIssue for
    # approval (draft -> pending_approval, via Inventory::StockIssueSubmission).
    # The issue already carries every clean row (attached at import time) and
    # every resolved row's item (attached as each one resolved). It NEVER
    # posts stock: the submitted issue follows the normal workflow — approve,
    # then "Confirm Issue" (Inventory::StockIssueConfirmationService) is the
    # only step that deducts stock.
    #
    # Before submitting, the whole issue is re-checked for availability with
    # the poster's own aggregate check (StockIssueImportRowResolver's
    # per-row checks are best-effort UI feedback only, and can't see two rows
    # for the same product); a short product's rows are detached and reopened
    # for the user to fix, instead of submitting an issue that can't be
    # confirmed. The poster re-checks authoritatively at confirmation.
    class StockIssueImportBatchCompleter
      Result = Struct.new(:ok, :batch, keyword_init: true) { def ok? = ok }

      def initialize(business, batch_id, user:)
        @business = business
        @batch_id = batch_id
        @user     = user
      end

      def call
        @batch = StockIssueImportBatch.where(business_id: @business.id).find(@batch_id)
        # A repeat "Complete Import" (double click, refresh) is a no-op — the
        # issue was already submitted exactly once.
        return Result.new(ok: true, batch: @batch) if @batch.completed?
        return Result.new(ok: false, batch: @batch) if @batch.rows.pending.exists?

        issue = @batch.stock_issue
        if issue.items.none?
          # Every row was skipped (or the import had nothing clean to begin
          # with) — nothing left to submit, so the batch is simply done.
          @batch.update!(status: :completed)
          return Result.new(ok: true, batch: @batch)
        end

        unless StockIssuePoster.new(issue).availability_ok?
          reopen_failed_rows!(issue)
          return Result.new(ok: false, batch: @batch.reload)
        end

        submit_and_finalize!(issue)
        Result.new(ok: true, batch: @batch.reload)
      rescue ActiveRecord::RecordInvalid
        Result.new(ok: false, batch: @batch.reload)
      end

      private

      # Submission and batch completion commit together, or not at all.
      def submit_and_finalize!(issue)
        ActiveRecord::Base.transaction do
          result = StockIssueSubmission.new(stock_issue_id: issue.id, actor: @user).call
          raise ActiveRecord::RecordInvalid, result.issue unless result.ok?

          @batch.rows.resolved.update_all(status: "imported")
          @batch.update!(status: :completed)
        end
      end

      def reopen_failed_rows!(issue)
        bad_skus = issue.errors.where(:base, :insufficient_stock).filter_map { |e| e.detail[:sku] }.to_set
        return if bad_skus.empty?

        @batch.rows.resolved.includes(:product, :stock_issue_item).each do |row|
          next unless row.product && bad_skus.include?(row.product.sku)

          # Clear the row's reference before destroying the item — the FK
          # points row -> item, so it must be nulled out first.
          item = row.stock_issue_item
          row.update!(status: :pending, failure_reason: :insufficient_stock,
                     available_hint: row.product.stock_in(@batch.warehouse), stock_issue_item: nil)
          item&.destroy
        end
      end
    end
  end
end
