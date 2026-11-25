module Inventory
  # Resolves what a receiver reported will not arrive (transfer status
  # "discrepancy", Phase D, decision D3). Per line, any part of the remaining
  # quantity (dispatched − received − already resolved) is:
  #
  #   return_to_source  transit OUT transit_out + source IN transfer_return
  #   write_off         transit OUT transfer_loss (the stock is gone)
  #
  # at the line's dispatch-time unit cost, dated on the resolution's Business
  # Day, each with an append-only StockTransferResolution row (actor, time,
  # Business Day, reason). A reason is mandatory. When nothing remains, the
  # transfer is received (closed); receipts and resolutions stay as history.
  # Never more than the remaining quantity, never a received unit; a resolution
  # can never be cancelled, edited or deleted.
  #
  # One transaction: transfer row lock (re-check discrepancy; remaining read
  # under it, so a repeated or concurrent resolution of the same units is
  # refused), both warehouses FOR SHARE (reached; the source must be active to
  # take a return), Product rows FOR UPDATE in id order, a final check that the
  # transit warehouse holds the units (never negative); post; audit
  # ("resolve", mandatory).
  #
  # Enforced here: resolve_stock_transfer_discrepancies and reach to BOTH warehouses.
  class StockTransferDiscrepancyResolution
    include AuditLoggable

    # entries: { stock_transfer_item_id => { "return_to_source" => qty, "write_off" => qty } }
    def initialize(stock_transfer_id:, actor:, entries:, reason:)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
      @entries           = normalize(entries)
      @reason            = reason.to_s.strip
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :resolve)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      return StockTransferWorkflow.failure(transfer, WarehouseReach.message) unless StockTransferWorkflow.reaches?(@actor, transfer)
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.discrepancy?
      return StockTransferWorkflow.failure(transfer, error_text(:resolution_reason_required)) if @reason.blank?
      return StockTransferWorkflow.failure(transfer, error_text(:invalid_quantity)) if @entries.nil?

      error = nil
      ActiveRecord::Base.transaction do
        transfer.lock!
        transfer.items.reset
        unless transfer.discrepancy?
          error = I18n.t("inventory.stock_transfers.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end
        returning = @entries.values.any? { |kinds| kinds["return_to_source"].to_d.positive? }
        if (error = StockTransferWorkflow.verify_warehouses_under_lock(@actor, transfer, reach: returning ? :both : :destination))
          raise ActiveRecord::Rollback
        end
        unless StockTransferWorkflow.reaches?(@actor, transfer)
          error = WarehouseReach.message
          raise ActiveRecord::Rollback
        end

        progress = StockTransferProgress.for(transfer)
        raise ActiveRecord::Rollback if (error = quantity_error(progress))

        items = progress.lines.map(&:item).select { |i| @entries.key?(i.id) }
        StockAvailability.lock_products!(items.map(&:product_id))
        transit = TransitWarehouse.find_for(transfer.business)
        raise ActiveRecord::Rollback if (error = transit_shortage_error(transit, items))

        resolved_on = BusinessDay.current(context: transfer.business)
        resolved_at = Time.current
        movement_ids = []
        resolutions = items.flat_map do |item|
          @entries.fetch(item.id).filter_map do |kind, quantity|
            next unless quantity.positive?

            movement_ids.concat(post!(transfer, transit, item, kind, quantity, resolved_on).map(&:id))
            transfer.resolutions.create!(business: transfer.business, stock_transfer_item: item, resolved_by: @actor,
                                         kind: kind, quantity: quantity, reason: @reason,
                                         resolved_at: resolved_at, resolved_on: resolved_on)
          end
        end

        resolved = resolutions.group_by(&:stock_transfer_item_id).transform_values { |list| list.sum(&:quantity) }
        remaining = progress.lines.to_h { |line| [ line.item.id, line.remaining - resolved.fetch(line.item.id, 0) ] }
        closed = remaining.values.all?(&:zero?)
        if closed
          transfer.status      = :received
          transfer.received_at = resolved_at
          transfer.save!
        else
          transfer.touch
        end
        log_audit!(actor: @actor, auditable: transfer, action: "resolve",
                   changes: (closed ? { status: [ "discrepancy", "received" ] } : {}),
                   metadata: { reason: @reason, resolved_on: resolved_on.iso8601, movement_ids: movement_ids,
                               resolution_ids: resolutions.map(&:id),
                               resolved_lines: resolutions.map do |r|
                                 { item_id: r.stock_transfer_item_id, kind: r.kind, quantity: QuantityFormat.plain(r.quantity) }
                               end,
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

    def post!(transfer, transit, item, kind, quantity, resolved_on)
      if kind == "return_to_source"
        [ StockTransferLedger.leg!(transfer, item: item, warehouse: transit, direction: :out, reason: :transit_out,
                                             quantity: quantity, occurred_on: resolved_on),
          StockTransferLedger.leg!(transfer, item: item, warehouse: transfer.source_warehouse, direction: :in,
                                             reason: :transfer_return, quantity: quantity, occurred_on: resolved_on) ]
      else
        [ StockTransferLedger.leg!(transfer, item: item, warehouse: transit, direction: :out, reason: :transfer_loss,
                                             quantity: quantity, occurred_on: resolved_on) ]
      end
    end

    def normalize(entries)
      hash = entries.respond_to?(:to_unsafe_h) ? entries.to_unsafe_h : entries.to_h
      hash.each_with_object({}) do |(item_id, kinds), out|
        kinds = kinds.respond_to?(:to_unsafe_h) ? kinds.to_unsafe_h : kinds.to_h
        parsed = kinds.slice(*StockTransferResolution::KINDS).each_with_object({}) do |(kind, value), k|
          next if value.blank?

          quantity = BigDecimal(value.to_s)
          return nil if quantity.negative?

          k[kind.to_s] = quantity
        end
        out[Integer(item_id.to_s)] = parsed if parsed.any?
      end
    rescue ArgumentError, TypeError
      nil
    end

    def quantity_error(progress)
      by_item = progress.by_item_id
      return error_text(:unknown_line) if (@entries.keys - by_item.keys).any?
      return error_text(:nothing_to_resolve) if @entries.values.sum { |kinds| kinds.values.sum }.zero?

      over = @entries.find { |item_id, kinds| kinds.values.sum > by_item.fetch(item_id).remaining }
      return nil unless over

      line = by_item.fetch(over.first)
      I18n.t("inventory.stock_transfers.errors.resolve_exceeds_remaining",
             product: line.item.product.name, requested: QuantityFormat.plain(over.last.values.sum),
             remaining: QuantityFormat.plain(line.remaining))
    end

    def transit_shortage_error(transit, items)
      return error_text(:transit_missing) if transit.nil?

      on_hand = StockTransferLedger.transit_on_hand(transit, items.map(&:product_id))
      needed = items.group_by(&:product_id).transform_values { |list| list.sum { |i| @entries.fetch(i.id).values.sum } }
      needed.any? { |product_id, quantity| on_hand[product_id].to_d < quantity } ? error_text(:transit_balance_short) : nil
    end

    def error_text(key) = I18n.t("inventory.stock_transfers.errors.#{key}")
  end
end
