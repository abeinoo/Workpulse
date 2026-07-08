module Inventory
  module Imports
    # Resolves a single row of a draft StockIssueImportBatch — the inline-edit
    # counterpart to StockIssueImporter. A successful resolve appends (or
    # updates) this row's line item on the batch's one draft StockIssue right
    # away; a row that goes back to pending (or gets skipped) has its item
    # removed again, so the draft always reflects exactly what's currently
    # resolved. Nothing is ever posted here — the final, authoritative
    # availability check happens once, when StockIssueImportBatchCompleter
    # posts that same draft issue.
    class StockIssueImportRowResolver
      Result = Struct.new(:ok, :row, keyword_init: true) { def ok? = ok }

      def initialize(business, row_id, product_id: nil, sku: nil, quantity: nil, skip: false)
        @business   = business
        @row_id     = row_id
        @product_id = product_id
        @sku        = sku
        @quantity   = quantity
        @skip       = skip
      end

      def call
        @row = StockIssueImportRow.joins(:batch)
                                  .where(stock_issue_import_batches: { business_id: @business.id })
                                  .find(@row_id)
        return skip_row! if @skip

        apply_edits
        resolve
      end

      private

      def apply_edits
        @row.sku = @sku.strip if @sku.present?
        @row.quantity = decimal(@quantity) if @quantity.present?
      end

      def resolve
        product = resolve_product

        if product.nil?
          return pending!(:unknown_sku, product: nil)
        end

        unless @row.quantity&.positive?
          return pending!(:invalid_row, product: product)
        end

        available = product.stock_in(@row.batch.warehouse)
        if @row.quantity > available
          return pending!(:insufficient_stock, product: product, available_hint: available)
        end

        item = attach_item!(product, @row.quantity)
        @row.update!(product: product, failure_reason: nil, status: :resolved,
                    available_hint: available, stock_issue_item: item)
        Result.new(ok: true, row: @row)
      end

      # A row already resolved to a product keeps that product when only the
      # quantity changes (the insufficient-stock flow); a SKU edit or an
      # explicit product selection always re-resolves from scratch.
      def resolve_product
        return @business.products.transactable.find_by(id: @product_id) if @product_id.present?
        return @row.product if @sku.blank? && @row.product.present?
        return nil if @row.sku.blank?

        @business.products.transactable.find_by("LOWER(sku) = ?", @row.sku.downcase)
      end

      # Creates this row's line item on the batch's draft issue the first time
      # it resolves; a later re-resolve (e.g. an edited quantity) updates that
      # same item in place instead of adding a second one.
      def attach_item!(product, quantity)
        if @row.stock_issue_item
          @row.stock_issue_item.update!(product: product, quantity: quantity)
          @row.stock_issue_item
        else
          @row.batch.stock_issue.items.create!(product: product, quantity: quantity)
        end
      end

      # Clears the row's reference to its item before destroying the item
      # itself — the FK points row -> item, so it must be nulled out first or
      # the delete violates that constraint.
      def detach_item!
        item = @row.stock_issue_item
        return unless item

        @row.update!(stock_issue_item: nil)
        item.destroy
      end

      def pending!(reason, product:, available_hint: nil)
        detach_item!
        @row.update!(product: product, failure_reason: reason, status: :pending, available_hint: available_hint)
        Result.new(ok: false, row: @row)
      end

      def skip_row!
        detach_item!
        @row.update!(status: :skipped, failure_reason: nil)
        Result.new(ok: true, row: @row)
      end

      def decimal(value)
        BigDecimal(value.to_s.strip)
      rescue ArgumentError, TypeError
        0
      end
    end
  end
end
