module Inventory
  # Posts a warehouse-to-warehouse transfer: validates that every product has
  # enough on-hand in the SOURCE warehouse, then records a paired OUT (source)
  # and IN (destination) movement per line. Quantity moves between warehouses;
  # the product's average cost is unchanged (same product, same business), so
  # both movements are valued at the current average cost for ledger consistency.
  # All-or-nothing in one transaction.
  class StockTransferPoster
    Result = Struct.new(:ok, :transfer, keyword_init: true) do
      def ok? = ok
    end

    def initialize(transfer)
      @transfer = transfer
    end

    def call
      value_items
      unless valid_warehouses? && availability_ok?
        return Result.new(ok: false, transfer: @transfer)
      end

      ActiveRecord::Base.transaction do
        @transfer.transfer_number = NumberSequencer.new(@transfer.business, :stock_transfer).next_number if @transfer.transfer_number.blank?

        raise ActiveRecord::Rollback unless @transfer.save

        @transfer.items.each { |item| post_item(item) }
        return Result.new(ok: true, transfer: @transfer)
      end

      Result.new(ok: false, transfer: @transfer)
    end

    private

    def value_items
      @transfer.items.each do |item|
        next if item.product.nil?
        item.unit_cost = item.product.average_cost_price
      end
    end

    # Surfaces the "same warehouse" validation early so availability isn't even
    # checked against a nonsensical source == destination.
    def valid_warehouses?
      @transfer.valid?
      @transfer.errors[:destination_warehouse_id].empty?
    end

    # Sums requested quantity per product and compares against on-hand in the
    # source warehouse, blocking transfers that would overdraw it.
    def availability_ok?
      ok = true
      @transfer.items.reject(&:marked_for_destruction?)
               .group_by(&:product_id).each do |_product_id, items|
        product = items.first.product
        next if product.nil?

        requested = items.sum { |i| i.quantity.to_d }
        available = product.stock_in(@transfer.source_warehouse)
        next if requested <= available

        ok = false
        @transfer.errors.add(:base, :insufficient_stock,
                             product:   product.name,
                             sku:       product.sku,
                             available: available.to_s,
                             requested: requested.to_s)
      end

      ok
    end

    def post_item(item)
      common = {
        business:    @transfer.business,
        product:     item.product,
        quantity:    item.quantity,
        unit_cost:   item.unit_cost,
        occurred_on: @transfer.transferred_on
      }

      @transfer.inventory_movements.create!(
        common.merge(warehouse: @transfer.source_warehouse,      direction: :out, reason: :transfer_out)
      )
      @transfer.inventory_movements.create!(
        common.merge(warehouse: @transfer.destination_warehouse, direction: :in,  reason: :transfer_in)
      )
    end
  end
end
