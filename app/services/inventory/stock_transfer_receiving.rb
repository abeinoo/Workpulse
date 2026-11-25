module Inventory
  # Records one receipt of an in-transit transfer at its destination (Phase C).
  # Partial receipts are normal: each receipt takes, per line, at most what is
  # still in transit (dispatched − received − resolved, Inventory::StockTransferProgress)
  # — never more (D4: excess goes through a destination Stock Adjustment).
  #
  #   per received line: transit OUT transit_out + destination IN transfer_in
  #
  # at the line's dispatch-time unit cost, dated on the receipt's Business Day,
  # together with the append-only StockTransferReceipt / lines. Then:
  #
  #   nothing left in transit           -> received
  #   close_shortfall (receiver declares nothing more will arrive)
  #                                     -> discrepancy: the remainder awaits a
  #                                        resolution (Inventory::StockTransferDiscrepancyResolution)
  #   otherwise                         -> stays in_transit (partially received, derived)
  #
  # One transaction: transfer row lock (re-check in_transit; the remaining
  # quantities are read under it, so two receipts of the same units serialize
  # and the second sees them received), the destination FOR SHARE (active,
  # reached), Product rows FOR UPDATE in id order, the destination's
  # availability rows; a final check that the transit warehouse holds every
  # unit being received (never negative); post; audit ("receive", mandatory).
  #
  # Enforced here: receive_stock_transfers and reach to the DESTINATION warehouse.
  class StockTransferReceiving
    include AuditLoggable

    # quantities: { stock_transfer_item_id => quantity received now }.
    def initialize(stock_transfer_id:, actor:, quantities:, notes: nil, close_shortfall: false)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
      @quantities        = normalize(quantities)
      @notes             = notes.to_s.strip.presence
      @close_shortfall   = ActiveModel::Type::Boolean.new.cast(close_shortfall) || false
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :receive)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      unless StockTransferWorkflow.reaches_side?(@actor, transfer, :destination)
        return StockTransferWorkflow.failure(transfer, WarehouseReach.message)
      end
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.in_transit?
      return StockTransferWorkflow.failure(transfer, error_text(:invalid_quantity)) if @quantities.nil?

      error = nil
      receipt = nil
      ActiveRecord::Base.transaction do
        transfer.lock!
        transfer.items.reset
        unless transfer.in_transit?
          error = I18n.t("inventory.stock_transfers.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end
        if (error = StockTransferWorkflow.verify_warehouses_under_lock(@actor, transfer, reach: :destination))
          raise ActiveRecord::Rollback
        end

        progress = StockTransferProgress.for(transfer)
        raise ActiveRecord::Rollback if (error = quantity_error(progress))

        received = @quantities.select { |_, q| q.positive? }
        items    = progress.lines.map(&:item).select { |i| received.key?(i.id) }
        StockAvailability.lock_products!(items.map(&:product_id))
        transit = TransitWarehouse.find_for(transfer.business)
        raise ActiveRecord::Rollback if (error = transit_shortage_error(transit, items, received))

        guard = IncomingAvailabilityGuard.new(warehouse_id: transfer.destination_warehouse_id, product_ids: items.map(&:product_id))
        if guard.refuse!(transfer)
          error = transfer.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end

        received_on = BusinessDay.current(context: transfer.business)
        receipt = transfer.receipts.create!(business: transfer.business, received_by: @actor, received_at: Time.current,
                                            received_on: received_on, closes_with_shortfall: @close_shortfall, notes: @notes)
        movement_ids = items.flat_map do |item|
          quantity = received.fetch(item.id)
          receipt.lines.create!(stock_transfer_item: item, quantity: quantity)
          [ StockTransferLedger.leg!(transfer, item: item, warehouse: transit, direction: :out, reason: :transit_out,
                                               quantity: quantity, occurred_on: received_on),
            StockTransferLedger.leg!(transfer, item: item, warehouse: transfer.destination_warehouse, direction: :in,
                                               reason: :transfer_in, quantity: quantity, occurred_on: received_on) ].map(&:id)
        end

        remaining = progress.lines.to_h { |line| [ line.item.id, line.remaining - received.fetch(line.item.id, 0) ] }
        to = if remaining.values.all?(&:zero?) then "received"
        elsif @close_shortfall then "discrepancy"
        else "in_transit"
        end
        if to != "in_transit"
          transfer.status = to
          transfer.received_at = Time.current if to == "received"
          transfer.save!
        else
          transfer.touch
        end
        log_audit!(actor: @actor, auditable: transfer, action: "receive",
                   changes: (to == "in_transit" ? {} : { status: [ "in_transit", to ] }),
                   metadata: { receipt_id: receipt.id, received_on: received_on.iso8601, movement_ids: movement_ids,
                               closes_with_shortfall: @close_shortfall, notes: @notes,
                               received_lines: received.transform_keys(&:to_s).transform_values { QuantityFormat.plain(_1) },
                               remaining: remaining.reject { |_, q| q.zero? }.transform_keys(&:to_s).transform_values { QuantityFormat.plain(_1) } })
      end
      return StockTransferWorkflow.failure(transfer.reload, error) if error

      StockTransferWorkflow.success(transfer)
    rescue ActiveRecord::RecordInvalid => e
      StockTransferWorkflow.failure(transfer.reload, e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      StockTransferWorkflow.failure(transfer.reload, I18n.t("inventory.stock_transfers.errors.audit_failed"))
    end

    private

    def normalize(quantities)
      hash = quantities.respond_to?(:to_unsafe_h) ? quantities.to_unsafe_h : quantities.to_h
      hash.each_with_object({}) do |(item_id, value), out|
        next if value.blank?

        quantity = BigDecimal(value.to_s)
        return nil if quantity.negative?

        out[Integer(item_id.to_s)] = quantity
      end
    rescue ArgumentError, TypeError
      nil
    end

    def quantity_error(progress)
      by_item = progress.by_item_id
      return error_text(:unknown_line) if (@quantities.keys - by_item.keys).any?
      return error_text(:nothing_to_receive) if @quantities.values.none?(&:positive?) && !@close_shortfall

      over = @quantities.find { |item_id, quantity| quantity > by_item.fetch(item_id).remaining }
      return nil unless over

      line = by_item.fetch(over.first)
      I18n.t("inventory.stock_transfers.errors.receive_exceeds_remaining",
             product: line.item.product.name, requested: QuantityFormat.plain(over.last),
             remaining: QuantityFormat.plain(line.remaining))
    end

    # The transit warehouse must hold every unit received now (it never goes negative).
    def transit_shortage_error(transit, items, received)
      return error_text(:transit_missing) if transit.nil? && items.any?

      on_hand = StockTransferLedger.transit_on_hand(transit, items.map(&:product_id))
      needed = items.group_by(&:product_id).transform_values { |list| list.sum { |i| received.fetch(i.id) } }
      short = needed.find { |product_id, quantity| on_hand[product_id].to_d < quantity }
      short ? error_text(:transit_balance_short) : nil
    end

    def error_text(key) = I18n.t("inventory.stock_transfers.errors.#{key}")
  end
end
