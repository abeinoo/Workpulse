module Inventory
  # Stock on its way INTO a warehouse through stock transfers, per product —
  # never counted twice: a transfer not yet dispatched (pending approval or
  # approved, awaiting dispatch) counts its lines; a dispatched one only what
  # is still in transit (dispatched − received − resolved) while it may still
  # arrive (in_transit; not after a receiver closed it with a shortfall).
  # Drafts count nothing. Used by the transfer form and Inventory::TransferReplenishment;
  # four grouped queries, whatever the product count.
  module TransferIncoming
    module_function

    # { product_id => quantity } (BigDecimal, 0 when nothing is on its way).
    def by_product(business_id:, warehouse_id:, product_ids:)
      ids = Array(product_ids).compact.uniq
      return {} if ids.empty?

      toward  = StockTransfer.where(business_id: business_id, destination_warehouse_id: warehouse_id).active
      pending = StockTransferItem.joins(:stock_transfer).merge(toward.where(status: StockTransfer::RESERVING_STATUSES))
                                 .where(product_id: ids).group(:product_id).sum(:quantity)
      # Only what may still arrive: a transfer closed with a shortfall
      # (discrepancy) declared its remainder will not.
      open_ids   = toward.in_transit.select(:id)
      dispatched = StockTransferItem.where(stock_transfer_id: open_ids, product_id: ids).group(:product_id).sum(:quantity)
      received   = StockTransferReceiptLine.joins(:stock_transfer_item)
                                           .where(stock_transfer_items: { stock_transfer_id: open_ids, product_id: ids })
                                           .group("stock_transfer_items.product_id").sum(:quantity)
      resolved   = StockTransferResolution.joins(:stock_transfer_item)
                                          .where(stock_transfer_id: open_ids, stock_transfer_items: { product_id: ids })
                                          .group("stock_transfer_items.product_id").sum(:quantity)
      ids.index_with { |id| pending[id].to_d + dispatched[id].to_d - received[id].to_d - resolved[id].to_d }
    end
  end
end
