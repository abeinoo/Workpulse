module Inventory
  # Per line of a transfer: how much was dispatched, received and resolved,
  # and what is still in transit — DERIVED from the append-only receipt and
  # resolution ledgers, never stored:
  #
  #   remaining = dispatched − received − returned − written off
  #
  # dispatched is the line's quantity once the transfer was dispatched (fixed
  # from approval on), 0 before. Two grouped queries for the whole transfer.
  class StockTransferProgress
    Line = Struct.new(:item, :requested, :dispatched, :received, :returned, :written_off, keyword_init: true) do
      def resolved  = returned + written_off
      def remaining = [ dispatched - received - resolved, 0 ].max
    end

    # items: the transfer's lines already loaded by the caller (with what its
    # view needs preloaded); defaults to the association.
    def self.for(transfer, items: nil) = new(transfer, items: items)

    Totals = Struct.new(:dispatched, :received, :resolved, :last_received_at, keyword_init: true) do
      def remaining = [ dispatched - received - resolved, 0 ].max
    end

    # { transfer_id => Totals } for a page of dispatched transfers — three
    # grouped queries, whatever the count (list pages, never per row).
    def self.totals_for(transfers)
      ids = transfers.map(&:id)
      return {} if ids.empty?

      dispatched = StockTransferItem.where(stock_transfer_id: ids).group(:stock_transfer_id).sum(:quantity)
      receipts   = StockTransferReceiptLine.joins(:stock_transfer_receipt)
                                           .where(stock_transfer_receipts: { stock_transfer_id: ids })
                                           .group("stock_transfer_receipts.stock_transfer_id")
                                           .pluck("stock_transfer_receipts.stock_transfer_id", Arel.sql("SUM(stock_transfer_receipt_lines.quantity)"),
                                                  Arel.sql("MAX(stock_transfer_receipts.received_at)"))
                                           .to_h { |id, qty, at| [ id, [ qty, at ] ] }
      resolved   = StockTransferResolution.where(stock_transfer_id: ids).group(:stock_transfer_id).sum(:quantity)
      transfers.to_h do |t|
        received_qty, last_at = receipts[t.id]
        [ t.id, Totals.new(dispatched: t.dispatched? ? dispatched[t.id].to_d : 0.to_d, received: received_qty.to_d,
                           resolved: resolved[t.id].to_d, last_received_at: last_at) ]
      end
    end

    def initialize(transfer, items: nil)
      @transfer = transfer
      @items    = items
    end

    def lines
      @lines ||= begin
        received = StockTransferReceiptLine.joins(:stock_transfer_receipt)
                                           .where(stock_transfer_receipts: { stock_transfer_id: @transfer.id })
                                           .group(:stock_transfer_item_id).sum(:quantity)
        resolved = StockTransferResolution.where(stock_transfer_id: @transfer.id)
                                          .group(:stock_transfer_item_id, :kind).sum(:quantity)
        (@items || @transfer.items).sort_by(&:id).map do |item|
          Line.new(item: item, requested: item.requested_quantity,
                   dispatched: @transfer.dispatched? ? item.quantity.to_d : 0.to_d,
                   received: received[item.id].to_d,
                   returned: resolved[[ item.id, "return_to_source" ]].to_d,
                   written_off: resolved[[ item.id, "write_off" ]].to_d)
        end
      end
    end

    def by_item_id = @by_item_id ||= lines.index_by { |line| line.item.id }

    def dispatched_total = lines.sum(&:dispatched)
    def received_total   = lines.sum(&:received)
    def resolved_total   = lines.sum(&:resolved)
    def remaining_total  = lines.sum(&:remaining)
    def outstanding?     = remaining_total.positive?
  end
end
