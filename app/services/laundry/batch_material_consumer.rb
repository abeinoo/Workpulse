module Laundry
  # Posts material consumption for a laundry batch against a warehouse (the
  # "Laundry Warehouse"). Reuses InventoryMovement directly — this is the only
  # new consumer of the inventory ledger the laundry domain introduces (reason:
  # laundry_consumption). Cost is snapshotted from the product's current
  # average at posting time and never re-averages the product, exactly like
  # StockIssuePoster.
  class BatchMaterialConsumer
    Result = Struct.new(:ok, :consumption, :error, keyword_init: true) { def ok? = ok }

    def initialize(batch, warehouse)
      @batch     = batch
      @warehouse = warehouse
    end

    def call(product:, quantity:)
      quantity = quantity.to_d
      return Result.new(ok: false, error: I18n.t("laundry.batches.errors.invalid_quantity")) unless quantity.positive?

      available = product.stock_in(@warehouse)
      if quantity > available
        return Result.new(ok: false, error: I18n.t("laundry.batches.errors.insufficient_stock",
                                                    product: product.name, available: available.to_s))
      end

      unit_cost = product.average_cost_price
      consumption = nil

      ActiveRecord::Base.transaction do
        movement = InventoryMovement.create!(
          business:    @batch.business,
          product:     product,
          warehouse:   @warehouse,
          direction:   :out,
          reason:      :laundry_consumption,
          quantity:    quantity,
          unit_cost:   unit_cost,
          occurred_on: BusinessDay.current(context: @batch.business),
          source:      @batch
        )

        consumption = LaundryBatchConsumption.create!(
          laundry_batch:      @batch,
          product:             product,
          inventory_movement:  movement,
          quantity:             quantity,
          unit_cost_snapshot:   unit_cost,
          total_cost_snapshot:  unit_cost * quantity
        )
      end

      Result.new(ok: true, consumption: consumption)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
