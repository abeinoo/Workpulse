module Inventory
  # Read-only: what still prevents turning a product's "Track stock quantity"
  # off. Untracked products get no stock counts, low-stock alerts or reorder
  # settings, so tracking stays on while the product still holds stock or is
  # on an open inventory document — stock must never silently drop out of
  # inventory management. Across ALL warehouses of the product's business
  # (not limited to a user's scope: the switch is product-wide).
  class TrackingDependencies
    OPEN_PURCHASE_REQUEST_STATUSES = ProductAvailabilityManager::OPEN_PURCHASE_REQUEST_STATUSES
    OPEN_STOCK_ISSUE_STATUSES      = ProductAvailabilityManager::OPEN_STOCK_ISSUE_STATUSES
    OPEN_STOCK_COUNT_STATUSES      = ProductAvailabilityManager::OPEN_STOCK_COUNT_STATUSES

    def initialize(product)
      @product = product
    end

    # { key => count/quantity } — only the blocking ones (non-zero).
    def blockers
      @blockers ||= {
        on_hand_warehouses: on_hand_warehouses,
        open_purchase_request_lines:
          PurchaseRequestItem.joins(:purchase_request)
                             .where(product_id: @product.id, purchase_requests: { status: OPEN_PURCHASE_REQUEST_STATUSES }).count,
        open_stock_issue_lines:
          StockIssueItem.joins(:stock_issue).where(product_id: @product.id, stock_issues: { status: OPEN_STOCK_ISSUE_STATUSES }).count,
        draft_goods_receipt_lines:
          GoodsReceiptItem.joins(:goods_receipt).where(product_id: @product.id, goods_receipts: { status: "draft" }).count,
        open_stock_count_lines:
          StockCountItem.joins(:stock_count).where(product_id: @product.id, stock_counts: { status: OPEN_STOCK_COUNT_STATUSES }).count
      }.select { |_key, value| value.positive? }
    end

    def blocked? = blockers.any?

    private

    # Warehouses where the ledger on-hand is not zero (either sign).
    def on_hand_warehouses
      InventoryMovement.where(product_id: @product.id).group(:warehouse_id)
                       .sum(Arel.sql(StockLevels::SIGNED)).count { |_id, qty| qty.to_d.nonzero? }
    end
  end
end
