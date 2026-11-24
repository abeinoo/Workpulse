module Inventory
  # The most recent goods receipts, stock issues and stock transfers whose
  # lines reference one product — for traceability on the product page.
  # Read-only.
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
  #
  # Stock transfers have no workflow: a transfer posts on creation (out of the
  # source, into the destination) and can only be voided, which reverses both
  # movements. #stock_transfer_summary counts every transfer of the product the
  # viewer may open — the same scoped relation as the rows, not just the
  # latest STOCK_TRANSFERS_LIMIT shown.
  class ProductRecentDocuments
    GOODS_RECEIPTS_LIMIT = 1
    STOCK_ISSUES_LIMIT   = 5
    STOCK_TRANSFERS_LIMIT = 10

    # direction (stock transfers only): the transfer seen from the viewer's
    # warehouses — :outgoing (only the source is theirs), :incoming (only the
    # destination), :internal (both); nil when the viewer reaches every
    # warehouse of the business (every transfer is internal to them).
    Row = Struct.new(:document, :quantity, :stock_effect, :direction, keyword_init: true) do
      def posted?   = stock_effect == :posted
      def reversed? = stock_effect == :reversed

      # Whether the viewer reaches this end (:source / :destination) of a
      # stock transfer. The transfer itself is visible when either end is
      # reachable (StockTransferPolicy::Scope); details beyond the warehouse
      # name — its branch — are shown only for a reachable end. Unrestricted
      # viewers (direction nil) reach both.
      def transfer_end_reachable?(side)
        case direction
        when nil, :internal then true
        when :outgoing then side == :source
        when :incoming then side == :destination
        else false
        end
      end
    end

    TransferSummary = Struct.new(:total, :posted, :voided, keyword_init: true)

    # stock_transfers: the policy-scoped StockTransfer relation (nil when the
    # caller does not show transfers); viewer_warehouse_ids: the viewer's
    # inventory warehouse ids (nil = every warehouse), for Row#direction only —
    # visibility is the scoped relation's alone.
    def initialize(product, goods_receipts:, stock_issues:, stock_transfers: nil, viewer_warehouse_ids: nil)
      @product              = product
      @goods_receipts       = goods_receipts
      @stock_issues         = stock_issues
      @stock_transfers      = stock_transfers
      @viewer_warehouse_ids = viewer_warehouse_ids
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

    def stock_transfers
      @stock_transfer_rows ||= begin
        transfers = transfers_with_product.includes({ source_warehouse: :branch }, { destination_warehouse: :branch }, :created_by)
                                          .recent
                                          .limit(STOCK_TRANSFERS_LIMIT)
        rows(transfers, StockTransferItem, :stock_transfer_id) { |transfer| transfer.voided? ? :reversed : :posted }
          .each { |row| row.direction = transfer_direction(row.document) }
      end
    end

    # One grouped COUNT over the same scoped relation as the rows.
    def stock_transfer_summary
      @stock_transfer_summary ||= begin
        counts = transfers_with_product.group(Arel.sql("stock_transfers.voided_at IS NULL")).count
        posted = counts.fetch(true, 0)
        voided = counts.fetch(false, 0)
        TransferSummary.new(total: posted + voided, posted: posted, voided: voided)
      end
    end

    private

    def transfers_with_product
      raise ArgumentError, "stock_transfers relation not given" if @stock_transfers.nil?

      @stock_transfers.where(id: StockTransferItem.where(product_id: @product.id).select(:stock_transfer_id))
    end

    def transfer_direction(transfer)
      return nil if @viewer_warehouse_ids.nil?

      source      = @viewer_warehouse_ids.include?(transfer.source_warehouse_id)
      destination = @viewer_warehouse_ids.include?(transfer.destination_warehouse_id)
      if source && destination then :internal
      elsif source             then :outgoing
      elsif destination        then :incoming
      end
    end

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
