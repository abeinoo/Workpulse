module Inventory
  # "Get Low-Stock Products" for a stock transfer (Stock Transfer redesign,
  # decisions D6–D8): which products the DESTINATION needs, and how many the
  # SOURCE can supply. A suggestion tool only — it creates nothing, reserves
  # nothing and bypasses no validation (submission re-checks everything under
  # lock). Its own calculation, scoped to transfers: Inventory::LowStockQuery
  # and the low-stock alerts are unchanged.
  #
  # Candidates: Active availability rows of the destination with a
  # low_stock_level above 0, for active products. For each:
  #
  #   position  = on hand − reserved + incoming          (destination)
  #   incoming  = in transit toward the destination (dispatched − received − resolved)
  #             + pending / approved-not-dispatched transfers toward it
  #   eligible  when position <= low_stock_level
  #   suggested = reorder_quantity when > 0, otherwise the deficit to reach
  #               low_stock_level (minimum 1)
  #   proposed  = suggested capped at the source's available (on hand − reserved)
  #
  # A product the source cannot supply at all is still listed, flagged
  # :unavailable (never silently left out); one it can supply only in part is
  # :partial. A fixed number of grouped queries, whatever the product count.
  class TransferReplenishment
    Suggestion = Struct.new(:product, :setting, :on_hand, :reserved, :incoming, :low_stock_level, :reorder_quantity,
                            :suggested, :source_available, keyword_init: true) do
      def position = on_hand - reserved + incoming
      def proposed = [ suggested, source_available ].min.then { |q| q.positive? ? q : 0.to_d }

      def status
        return :unavailable unless source_available.positive?

        source_available < suggested ? :partial : :ok
      end

      def selectable? = status != :unavailable
    end

    def initialize(business:, source_warehouse_id:, destination_warehouse_id:)
      @business       = business
      @source_id      = Integer(source_warehouse_id)
      @destination_id = Integer(destination_warehouse_id)
    end

    def suggestions
      @suggestions ||= begin
        settings = candidate_settings
        ids = settings.map(&:product_id)
        if ids.empty?
          []
        else
          on_hand  = StockAvailability.on_hand_by(warehouse_ids: [ @source_id, @destination_id ], product_ids: ids)
          reserved = StockAvailability.reserved_by(warehouse_ids: [ @source_id, @destination_id ], product_ids: ids)
          incoming = incoming_by_product(ids)
          rows = settings.map do |setting|
            build(setting, on_hand, reserved, incoming)
          end
          rows.select { |row| row.position <= row.low_stock_level }
              .sort_by { |row| [ row.selectable? ? 0 : 1, row.position - row.low_stock_level, row.product.name.to_s ] }
        end
      end
    end

    private

    def candidate_settings
      ProductWarehouseSetting.where(business_id: @business.id, warehouse_id: @destination_id, status: "active")
                             .where("product_warehouse_settings.low_stock_level > 0")
                             .joins(:product).merge(Product.transactable)
                             .includes(:product).to_a
    end

    def build(setting, on_hand, reserved, incoming)
      product_id = setting.product_id
      destination_on_hand  = on_hand[[ @destination_id, product_id ]].to_d
      destination_reserved = reserved[[ @destination_id, product_id ]].to_d
      source_available     = on_hand[[ @source_id, product_id ]].to_d - reserved[[ @source_id, product_id ]].to_d
      position = destination_on_hand - destination_reserved + incoming[product_id].to_d
      Suggestion.new(product: setting.product, setting: setting, on_hand: destination_on_hand,
                     reserved: destination_reserved, incoming: incoming[product_id].to_d,
                     low_stock_level: setting.low_stock_level.to_d, reorder_quantity: setting.reorder_quantity.to_d,
                     suggested: suggested_quantity(setting, position),
                     source_available: [ source_available, 0 ].max)
    end

    def suggested_quantity(setting, position)
      return setting.reorder_quantity.to_d if setting.reorder_quantity.to_d.positive?

      [ setting.low_stock_level.to_d - position, 1 ].max
    end

    def incoming_by_product(product_ids)
      TransferIncoming.by_product(business_id: @business.id, warehouse_id: @destination_id, product_ids: product_ids)
    end
  end
end
