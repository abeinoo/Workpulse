module Laundry
  # Posts material consumption for a laundry batch against a warehouse (the
  # "Laundry Warehouse"). Reuses InventoryMovement directly — this is the only
  # new consumer of the inventory ledger the laundry domain introduces (reason:
  # laundry_consumption). Cost is snapshotted from the product's current
  # average at posting time and never re-averages the product, exactly like
  # StockIssuePoster.
  #
  # BUG-073: the product row is locked (Inventory::StockAvailability
  # .lock_products!, the lock every posting takes) and availability, approved
  # reservations and the average are read inside the transaction that writes
  # the movement, so two consumptions — or a consumption and an issue
  # approval / posting — cannot both take the same stock.
  class BatchMaterialConsumer
    Result = Struct.new(:ok, :consumption, :error, keyword_init: true) { def ok? = ok }

    def initialize(batch, warehouse)
      @batch     = batch
      @warehouse = warehouse
    end

    def call(product:, quantity:)
      quantity = quantity.to_d
      return Result.new(ok: false, error: I18n.t("laundry.batches.errors.invalid_quantity")) unless quantity.positive?

      consumption = nil
      error = nil

      ActiveRecord::Base.transaction do
        Inventory::StockAvailability.lock_products!([ product.id ])
        available = product.stock_in(@warehouse)
        if quantity > available
          error = I18n.t("laundry.batches.errors.insufficient_stock",
                         product: product.name, available: Inventory::StockAvailability.format_quantity(available))
          raise ActiveRecord::Rollback
        end

        holder = LaundryBatchConsumption.new
        unless Inventory::StockAvailability.protect_reservations!(holder, warehouse: @warehouse, removals: { product.id => quantity })
          error = holder.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end

        unit_cost = Inventory::StockAvailability.locked_averages([ product.id ]).fetch(product.id).to_d
        occurred  = BusinessDay.current(context: @batch.business)
        movement = InventoryMovement.create!(
          business:    @batch.business,
          product:     product,
          warehouse:   @warehouse,
          direction:   :out,
          reason:      :laundry_consumption,
          quantity:    quantity,
          unit_cost:   unit_cost,
          occurred_on: occurred,
          source:      @batch
        )

        consumption = LaundryBatchConsumption.create!(
          laundry_batch:      @batch,
          product:             product,
          inventory_movement:  movement,
          quantity:             quantity,
          unit_cost_snapshot:   unit_cost,
          total_cost_snapshot:  (unit_cost * quantity).round(4)
        )
      end

      return Result.new(ok: false, error: error) if error

      Result.new(ok: true, consumption: consumption)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, error: e.record.errors.full_messages.to_sentence)
    end
  end
end
