module Inventory
  module Reports
    # Transfer report: one row per transferred product line. Transfers post
    # (move stock) the moment they are saved — there is no draft stage — so
    # the only states are posted and voided. Voided transfers are excluded
    # unless status: "voided" or "all" is asked for explicitly.
    class Transfers
      STATUSES = %w[posted voided all].freeze

      Row = Struct.new(:transfer, :item, :product, :quantity, :unit_cost, :total_cost, keyword_init: true) do
        def voided? = transfer.voided_at.present?
      end

      def initialize(business, warehouse_ids: nil, product_id: nil, from: nil, to: nil, status: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @product_id    = product_id
        @from          = Movements.parse_date(from)
        @to            = Movements.parse_date(to)
        @status        = status.presence_in(STATUSES) || "posted"
      end

      def rows
        @rows ||= items.map do |item|
          Row.new(transfer: item.stock_transfer, item: item, product: item.product,
                  quantity: item.quantity, unit_cost: item.unit_cost, total_cost: item.total_cost)
        end
      end

      def total_quantity = rows.reject(&:voided?).sum(&:quantity)
      def total_value    = rows.reject(&:voided?).sum(&:total_cost)

      private

      def items
        transfers = @business.stock_transfers
        transfers = case @status
        when "posted" then transfers.active
        when "voided" then transfers.voided
        else transfers
        end
        # A scoped user sees a transfer when either end is one of their warehouses.
        if @warehouse_ids
          transfers = transfers.where(source_warehouse_id: @warehouse_ids)
                               .or(transfers.where(destination_warehouse_id: @warehouse_ids))
        end
        transfers = transfers.where("transferred_on >= ?", @from) if @from
        transfers = transfers.where("transferred_on <= ?", @to)   if @to

        rel = StockTransferItem.where(stock_transfer_id: transfers.select(:id))
                               .includes(:product, stock_transfer: %i[source_warehouse destination_warehouse])
                               .joins(:stock_transfer)
        rel = rel.where(product_id: @product_id) if @product_id.present?
        rel.order("stock_transfers.transferred_on DESC, stock_transfers.id DESC, stock_transfer_items.id")
      end
    end
  end
end
