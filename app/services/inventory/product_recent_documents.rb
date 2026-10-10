module Inventory
  # The most recent goods receipts and stock issues whose lines reference one
  # product — for traceability on the product page. Read-only.
  #
  # Callers pass the policy-scoped document relations (business + accessible
  # warehouses), so a document the viewer cannot open is never returned.
  # Every document is returned regardless of workflow state (draft, rejected,
  # cancelled, voided …) so the trail stays complete; #stock_effect says
  # whether its quantity is an actual stock movement, following the posting
  # rules: a goods receipt moves stock only once confirmed, a stock issue only
  # once issued, and voiding either posts a compensating reversal.
  #
  # Query cost is constant in the product's history size: one query per
  # document type (filtered by an item-level subquery, ordered and limited in
  # SQL) plus one grouped SUM for this product's quantities.
  class ProductRecentDocuments
    GOODS_RECEIPTS_LIMIT = 1
    STOCK_ISSUES_LIMIT   = 5

    Row = Struct.new(:document, :quantity, :stock_effect, keyword_init: true) do
      def posted?   = stock_effect == :posted
      def reversed? = stock_effect == :reversed
    end

    def initialize(product, goods_receipts:, stock_issues:)
      @product        = product
      @goods_receipts = goods_receipts
      @stock_issues   = stock_issues
    end

    def goods_receipts
      @goods_receipt_rows ||= rows(
        @goods_receipts.where(id: GoodsReceiptItem.where(product_id: @product.id).select(:goods_receipt_id))
                       .includes(:supplier, :warehouse)
                       .recent
                       .limit(GOODS_RECEIPTS_LIMIT),
        GoodsReceiptItem, :goods_receipt_id
      ) { |receipt| stock_effect(receipt, moved: receipt.confirmed?) }
    end

    def stock_issues
      @stock_issue_rows ||= rows(
        @stock_issues.where(id: StockIssueItem.where(product_id: @product.id).select(:stock_issue_id))
                     .includes(:warehouse, :branch, :created_by)
                     .recent
                     .limit(STOCK_ISSUES_LIMIT),
        StockIssueItem, :stock_issue_id
      ) { |issue| stock_effect(issue, moved: issue.issued?) }
    end

    private

    # A document may carry the product on more than one line — sum them.
    def rows(documents, item_class, foreign_key)
      documents = documents.to_a
      quantities = item_class.where(foreign_key => documents.map(&:id), product_id: @product.id)
                             .group(foreign_key).sum(:quantity)

      documents.map do |document|
        Row.new(document: document, quantity: quantities.fetch(document.id, 0), stock_effect: yield(document))
      end
    end

    def stock_effect(document, moved:)
      return :not_posted unless moved

      document.voided? ? :reversed : :posted
    end
  end
end
