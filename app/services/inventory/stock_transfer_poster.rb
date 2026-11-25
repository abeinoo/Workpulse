module Inventory
  # The PHYSICAL posting step of a stock transfer — internal to approval.
  # Invoked only by Inventory::StockTransferApproval, inside its transaction,
  # on the row-locked pending transfer; it is never a way to create or post a
  # transfer on its own (creating a transfer makes a draft —
  # Inventory::StockTransferDraftService). It refuses (ArgumentError) any
  # transfer that is not a persisted pending_approval row, and any call outside
  # an open transaction.
  #
  # Under the Product row locks (FOR UPDATE, id order — taken here again,
  # a no-op when the caller already holds them) it:
  #
  #   1. values every line at the product's current average, read from the
  #      locked rows (BUG-071) — quantity moves between warehouses, the
  #      average cost is unchanged;
  #   2. refuses a product whose availability in the DESTINATION warehouse is
  #      Inactive (Inventory::IncomingAvailabilityGuard; the source side is
  #      never checked);
  #   3. re-validates the source: every product must be available after what
  #      OTHER documents reserve (StockAvailability.validate_transfer! — the
  #      transfer's own reservation is excluded, so it is consumed, never
  #      counted against itself, and nothing is deducted twice);
  #   4. writes a paired OUT (source) and IN (destination) movement per line,
  #      dated posted_on (the approval Business Day).
  #
  # #post! returns true, or false with the reasons on transfer.errors (nothing
  # written by it that the caller's rollback would not undo). The caller
  # changes the status and writes the audit entry in the same transaction, so
  # stock can never leave the source without arriving at the destination.
  class StockTransferPoster
    def initialize(transfer, posted_on:)
      @transfer  = transfer
      @posted_on = posted_on
    end

    def post!
      ensure_internal_call!

      StockAvailability.lock_products!(lines.map(&:product_id))
      value_items
      return false unless destination_accepts_incoming?
      return false unless StockAvailability.validate_transfer!(@transfer)

      lines.each do |item|
        item.save!
        post_item(item)
      end
      true
    end

    # The movements this posting wrote (for the approval audit entry).
    def movement_ids = @movement_ids ||= []

    private

    def ensure_internal_call!
      unless @transfer.persisted? && @transfer.status_in_database == "pending_approval"
        raise ArgumentError, "StockTransferPoster posts only a persisted pending transfer, from its approval"
      end
      raise ArgumentError, "StockTransferPoster must run inside the approval transaction" unless StockTransfer.connection.transaction_open?
      raise ArgumentError, "posted_on is required" if @posted_on.nil?
    end

    def lines = @lines ||= @transfer.items.reject(&:marked_for_destruction?)

    # Valued with the average read under the product locks (BUG-071).
    def value_items
      averages = StockAvailability.locked_averages(lines.map(&:product_id))
      lines.each do |item|
        next if item.product.nil?
        item.unit_cost = averages.fetch(item.product_id, item.product.average_cost_price)
      end
    end

    # Runs under the product locks; locks the destination pair rows last.
    def destination_accepts_incoming?
      guard = IncomingAvailabilityGuard.new(warehouse_id: @transfer.destination_warehouse_id,
                                            product_ids:  lines.map(&:product_id))
      !guard.refuse!(@transfer)
    end

    def post_item(item)
      common = {
        business:    @transfer.business,
        product:     item.product,
        quantity:    item.quantity,
        unit_cost:   item.unit_cost,
        occurred_on: @posted_on
      }

      out = @transfer.inventory_movements.create!(
        common.merge(warehouse: @transfer.source_warehouse,      direction: :out, reason: :transfer_out)
      )
      inn = @transfer.inventory_movements.create!(
        common.merge(warehouse: @transfer.destination_warehouse, direction: :in,  reason: :transfer_in)
      )
      movement_ids.push(out.id, inn.id)
    end
  end
end
