module Inventory
  # Starts a stock count session: one row per transactable product, each with
  # the warehouse's current ledger quantity as a display snapshot (the
  # authoritative baseline is captured per product when it is counted — see
  # Inventory::StockCountRecorder). Audited as "create".
  #
  # The caller authorizes the warehouse (policy + warehouse assignment); the
  # model refuses another business's warehouse, and its on-hand is never read.
  class StockCountCreator
    include StockCountService

    def initialize(actor:, warehouse_id:, counted_on:, notes: nil)
      @actor        = actor
      @warehouse_id = warehouse_id
      @counted_on   = counted_on
      @notes        = notes
    end

    def call
      @count = @actor.business.stock_counts.build(
        warehouse_id: @warehouse_id, counted_on: @counted_on, notes: @notes, created_by: @actor
      )
      preload_products

      ActiveRecord::Base.transaction do
        @count.save!
        log_audit(actor: @actor, auditable: @count, action: "create",
                  metadata: { count_number: @count.count_number, warehouse_id: @count.warehouse_id,
                              counted_on: @count.counted_on.to_s, products: @count.items.size })
      end
      success
    rescue ActiveRecord::RecordInvalid
      failure(@count.errors.full_messages.to_sentence)
    end

    private

    def preload_products
      warehouse = @count.warehouse
      return if warehouse.nil? || warehouse.business_id != @actor.business_id

      products = @actor.business.products.transactable.ordered.to_a
      on_hand  = on_hand_for(products.map(&:id))
      products.each do |product|
        @count.items.build(product: product, system_quantity: on_hand[product.id].to_d)
      end
    end
  end
end
