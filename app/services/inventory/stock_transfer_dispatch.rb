module Inventory
  # awaiting_dispatch -> in_transit: the source side hands the approved stock
  # over (D1). The reservation is CONSUMED here — the stock leaves the source:
  #
  #   per line: source OUT transfer_out + transit IN transit_in (StockTransferLedger)
  #
  # into the business's system transit warehouse (Inventory::TransitWarehouse,
  # provisioned on first need), valued at the average read under the product
  # locks and fixed on the line as its dispatch-time unit cost. The business
  # total on-hand does not change, so the moving average and valuation stay
  # correct while the goods travel.
  #
  # One transaction, in the workflow's lock order: transfer row (re-check
  # awaiting_dispatch — a second dispatch sees in_transit and refuses), the
  # acting warehouse FOR SHARE (source: active, reached), the transit
  # warehouse (advisory lock while provisioning), Product rows FOR UPDATE in id
  # order; then re-validate availability against what OTHER documents reserve
  # (this transfer's own reservation excluded — it is what is being consumed)
  # and the destination's availability rows; post; record dispatcher, time and
  # Business Day (the transfer's date becomes the dispatch day); write the
  # mandatory "dispatch" audit entry. Any failure rolls everything back — no
  # partial movement, the reservation still held.
  #
  # Enforced here: dispatch_stock_transfers and reach to the SOURCE warehouse.
  class StockTransferDispatch
    include AuditLoggable

    def initialize(stock_transfer_id:, actor:)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :dispatch)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      unless StockTransferWorkflow.reaches_side?(@actor, transfer, :source)
        return StockTransferWorkflow.failure(transfer, WarehouseReach.message)
      end
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.awaiting_dispatch?

      error = nil
      ActiveRecord::Base.transaction do
        transfer.lock!
        transfer.items.reset
        unless transfer.awaiting_dispatch? && !transfer.voided?
          error = I18n.t("inventory.stock_transfers.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end
        if (error = StockTransferWorkflow.verify_warehouses_under_lock(@actor, transfer, reach: :source))
          raise ActiveRecord::Rollback
        end

        transit = TransitWarehouse.for!(transfer.business, actor: @actor)
        StockTransferWorkflow.lock_products!(transfer)
        guard = IncomingAvailabilityGuard.new(warehouse_id: transfer.destination_warehouse_id,
                                              product_ids: transfer.items.map(&:product_id))
        if guard.refuse!(transfer) || !StockAvailability.validate_transfer!(transfer)
          error = transfer.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end

        dispatched_on = BusinessDay.current(context: transfer.business)
        movement_ids  = post_legs!(transfer, transit, dispatched_on)
        transfer.status         = :in_transit
        transfer.dispatched_by  = @actor
        transfer.dispatched_at  = Time.current
        transfer.dispatched_on  = dispatched_on
        transfer.transferred_on = dispatched_on
        transfer.save!
        log_audit!(actor: @actor, auditable: transfer, action: "dispatch",
                   changes: { status: [ "awaiting_dispatch", "in_transit" ] },
                   metadata: { transfer_number: transfer.transfer_number, dispatched_on: dispatched_on.iso8601,
                               transit_warehouse_id: transit.id, movement_ids: movement_ids,
                               reservation_consumed: StockTransferWorkflow.quantity_totals(transfer),
                               dispatched_lines: transfer.items.map do |i|
                                 { product_id: i.product_id, quantity: QuantityFormat.plain(i.quantity),
                                   unit_cost: i.unit_cost.to_d.to_s("F") }
                               end })
      end
      return StockTransferWorkflow.failure(transfer.reload, error) if error

      StockTransferWorkflow.success(transfer)
    rescue ActiveRecord::RecordInvalid => e
      StockTransferWorkflow.failure(transfer.reload, e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      StockTransferWorkflow.failure(transfer.reload, I18n.t("inventory.stock_transfers.errors.audit_failed"))
    end

    private

    def post_legs!(transfer, transit, dispatched_on)
      averages = StockAvailability.locked_averages(transfer.items.map(&:product_id))
      transfer.items.flat_map do |item|
        item.unit_cost = averages.fetch(item.product_id, item.product.average_cost_price)
        item.save!
        [ StockTransferLedger.leg!(transfer, item: item, warehouse: transfer.source_warehouse, direction: :out,
                                             reason: :transfer_out, quantity: item.quantity, occurred_on: dispatched_on),
          StockTransferLedger.leg!(transfer, item: item, warehouse: transit, direction: :in,
                                             reason: :transit_in, quantity: item.quantity, occurred_on: dispatched_on) ].map(&:id)
      end
    end
  end
end
