module Inventory
  # Posts a goods receipt: assigns its number, persists it, and for each line
  # item records an IN movement (the stock increase) and rolls the product's
  # moving-average / last-purchase cost forward. All-or-nothing in one
  # transaction so a mid-way failure leaves no partial stock.
  class GoodsReceiptPoster
    Result = Struct.new(:ok, :receipt, keyword_init: true) do
      def ok? = ok
    end

    def initialize(receipt)
      @receipt = receipt
    end

    def call
      ActiveRecord::Base.transaction do
        @receipt.receipt_number = NumberSequencer.new(@receipt.business, :goods_receipt).next_number if @receipt.receipt_number.blank?

        unless @receipt.save
          raise ActiveRecord::Rollback
        end

        @receipt.items.each { |item| post_item(item) }
        return Result.new(ok: true, receipt: @receipt)
      end

      Result.new(ok: false, receipt: @receipt)
    end

    private

    def post_item(item)
      product = item.product
      # Read on-hand *before* this movement so the moving average is correct.
      on_hand_before = product.current_stock

      @receipt.inventory_movements.create!(
        business:    @receipt.business,
        product:     product,
        warehouse:   @receipt.warehouse,
        direction:   :in,
        reason:      :goods_receipt,
        quantity:    item.quantity,
        unit_cost:   item.unit_cost,
        occurred_on: @receipt.received_on
      )

      ProductCostUpdater.new(product).apply_receipt(
        quantity:       item.quantity,
        unit_cost:      item.unit_cost,
        on_hand_before: on_hand_before
      )
    end
  end
end
