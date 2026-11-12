module Inventory
  # Shared plumbing for the stock count lifecycle services
  # (Creator, Recorder, Completion, Approver, Reopener, Removal):
  #
  #   * one Result shape — ok / count / error (a user-facing message);
  #   * the count is loaded by id, scoped to the actor's business, and
  #     row-locked (FOR UPDATE) inside the caller's transaction, so every
  #     status check runs on the committed row and two requests for the same
  #     count serialize (double clicks, concurrent approve / reopen / delete);
  #   * ledger on-hand for many products in one query.
  module StockCountService
    include AuditLoggable

    Result = Struct.new(:ok, :count, :error, keyword_init: true) do
      def ok? = ok
    end

    private

    def scoped_counts
      StockCount.where(business_id: @actor.business_id)
    end

    # Locks and reloads the count; its items are reloaded too, so nothing
    # read before the lock is trusted.
    def lock_count!
      @count = scoped_counts.lock.find(@stock_count_id)
      @count.items.reset
      @count
    end

    # { product_id => on_hand } in the count's warehouse — the ledger
    # (InventoryMovement) on-hand, the quantity a physical count is compared to.
    def on_hand_for(product_ids)
      return {} if product_ids.empty?

      StockAvailability.on_hand_by(warehouse_ids: @count.warehouse_id, product_ids: product_ids.uniq)
                       .transform_keys { |(_warehouse_id, product_id)| product_id }
    end

    def success
      Result.new(ok: true, count: @count, error: nil)
    end

    def failure(message)
      Result.new(ok: false, count: @count, error: message)
    end

    def t_error(key, **options)
      I18n.t("inventory.stock_counts.errors.#{key}", **options)
    end

    def quantity_string(value)
      return nil if value.nil?

      d = value.to_d
      d.frac.zero? ? d.to_i.to_s : d.to_s("F")
    end
  end
end
