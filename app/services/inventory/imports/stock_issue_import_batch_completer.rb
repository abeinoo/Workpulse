module Inventory
  module Imports
    # "Complete Import" — posts the batch's single draft StockIssue, which
    # already carries every clean row (attached at import time) and every
    # resolved row's item (attached as each one resolved). This is the single,
    # authoritative availability check (StockIssueImportRowResolver's checks
    # are best-effort UI feedback only); if the poster still blocks on
    # insufficient stock — e.g. a race with stock consumed elsewhere since a
    # row was resolved — that row's item is detached and the row reopened for
    # the user to fix, instead of losing the whole batch.
    class StockIssueImportBatchCompleter
      Result = Struct.new(:ok, :batch, keyword_init: true) { def ok? = ok }

      def initialize(business, batch_id, user: nil)
        @business = business
        @batch_id = batch_id
        @user     = user
      end

      def call
        @batch = StockIssueImportBatch.where(business_id: @business.id).find(@batch_id)
        return Result.new(ok: false, batch: @batch) if @batch.rows.pending.exists?

        issue = @batch.stock_issue
        if issue.items.none?
          # Every row was skipped (or the import had nothing clean to begin
          # with) — nothing left to post, so the batch is simply done.
          @batch.update!(status: :completed)
          return Result.new(ok: true, batch: @batch)
        end

        result = StockIssuePoster.new(issue).call
        if result.ok?
          finalize!
        else
          reopen_failed_rows!(result.issue)
        end

        Result.new(ok: result.ok?, batch: @batch.reload)
      end

      private

      def finalize!
        ActiveRecord::Base.transaction do
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
