module Inventory
  # Shared pieces of the Stock Transfer workflow services
  # (StockTransferDraftService / Submission / Editor / Approval / Rejection /
  # Cancellation). Each service:
  #
  #   1. loads the transfer itself, scoped to the actor's business (never a
  #      controller-side object — CLAUDE.md "Services accept IDs");
  #   2. checks the operation permission (Inventory::StockTransferAuthorization)
  #      and the actor's reach to BOTH warehouses (Inventory::WarehouseReach);
  #   3. inside one transaction: locks the transfer row and re-checks its
  #      status, then (forward steps) re-verifies both warehouses FOR SHARE,
  #      then locks the Product rows FOR UPDATE in id order before reading
  #      availability — the same order as the Stock Issue workflow, so the two
  #      can never deadlock;
  #   4. writes its audit entry in that transaction.
  module StockTransferWorkflow
    Result = Struct.new(:ok, :transfer, :error, keyword_init: true) do
      def ok? = ok
    end

    module_function

    def find(actor, stock_transfer_id)
      StockTransfer.where(business_id: actor.business_id).find(stock_transfer_id)
    end

    def success(transfer) = Result.new(ok: true, transfer: transfer)

    def failure(transfer, error) = Result.new(ok: false, transfer: transfer, error: error)

    def reaches?(actor, transfer)
      transfer.business_id == actor.business_id &&
        WarehouseReach.permits?(actor, transfer.source_warehouse_id, transfer.destination_warehouse_id)
    end

    # Both STORED warehouses re-verified under the transfer lock (rows FOR
    # SHARE, so a concurrent deactivation cannot commit between this check and
    # the reservation / posting that follows): the ends the operation acts on
    # (reach: :both, :source or :destination) are of the transfer's business,
    # ACTIVE, and still reached by the actor. nil when fine, else the message.
    def verify_warehouses_under_lock(actor, transfer, reach: :both)
      ids = reach_ids(transfer, reach)
      rows = Warehouse.where(id: ids, business_id: transfer.business_id).order(:id).lock("FOR SHARE").to_a
      return I18n.t("inventory.stock_transfers.errors.warehouse_missing") if rows.size != ids.uniq.size

      inactive = rows.find { |w| !w.active? }
      return I18n.t("inventory.stock_transfers.errors.warehouse_inactive", warehouse: inactive.name) if inactive
      return WarehouseReach.message unless WarehouseReach.permits?(actor, *ids)

      nil
    end

    # The ends an operation needs the actor to reach: approval / editing /
    # resolution both, dispatch the source, receipt the destination.
    def reach_ids(transfer, reach)
      case reach
      when :source      then [ transfer.source_warehouse_id ]
      when :destination then [ transfer.destination_warehouse_id ]
      else [ transfer.source_warehouse_id, transfer.destination_warehouse_id ]
      end
    end

    def reaches_side?(actor, transfer, reach)
      transfer.business_id == actor.business_id && WarehouseReach.permits?(actor, *reach_ids(transfer, reach))
    end

    def invalid_transition(transfer)
      failure(transfer, I18n.t("inventory.stock_transfers.errors.invalid_transition"))
    end

    # [{ "product_id", "quantity" }] per line, sorted — the before/after shape
    # of every audit entry (and the original-request snapshot at submission).
    def line_snapshot(items)
      items.reject(&:marked_for_destruction?)
           .map { |i| { "product_id" => i.product_id, "quantity" => QuantityFormat.plain(i.quantity.to_d) } }
           .sort_by { |l| [ l["product_id"].to_i, l["quantity"].to_d ] }
    end

    # { product_id => quantity } as strings — what a status holds per product.
    def quantity_totals(transfer)
      transfer.requested_quantities.transform_keys(&:to_s).transform_values { |q| QuantityFormat.plain(q) }
    end

    # Per product, how the reservation changed: { product_id => [before, after] }.
    def reservation_delta(before, after)
      sum = ->(lines) { lines.group_by { |l| l["product_id"].to_s }.transform_values { |ls| ls.sum { |l| l["quantity"].to_d } } }
      b = sum.call(before)
      a = sum.call(after)
      (b.keys | a.keys).sort.each_with_object({}) do |product_id, delta|
        next if b[product_id].to_d == a[product_id].to_d

        delta[product_id] = [ QuantityFormat.plain(b[product_id].to_d), QuantityFormat.plain(a[product_id].to_d) ]
      end
    end

    def lock_products!(transfer, extra_product_ids = [])
      StockAvailability.lock_products!(transfer.items.map(&:product_id) + extra_product_ids)
    end
  end
end
