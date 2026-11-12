module Inventory
  # in_progress → completed: the counter submits the count for approval.
  # Completing NEVER posts inventory (decision D1) — only approval does.
  #
  # Decision D9 — legacy rows (a quantity entered before per-product count
  # times existed, never physically recounted) are not trusted: at the
  # completion cutoff each one adopts the warehouse's ledger on-hand,
  #   legacy_counted_quantity = the old unverified quantity (kept as history)
  #   counted_quantity = system_quantity = on-hand at the cutoff
  #   baseline_at = cutoff, counted_at = nil, quantity_source = "system"
  # so its difference is zero (no artificial adjustment) and every movement
  # after the cutoff is preserved. Physically counted rows keep their own count
  # times and baselines. Uncounted (blank) rows stay uncounted and are skipped
  # at approval, exactly as before.
  class StockCountCompletion
    include StockCountService

    def initialize(stock_count_id:, actor:)
      @stock_count_id = stock_count_id
      @actor          = actor
    end

    def call
      ActiveRecord::Base.transaction do
        lock_count!
        return failure(t_error("not_in_progress")) unless @count.in_progress?

        cutoff  = Time.current
        adopted = adopt_system_quantities!(cutoff)

        @count.update!(status: :completed, completed_at: cutoff, completed_by: @actor)
        log_audit!(actor: @actor, auditable: @count, action: "complete",
                   changes: { status: %w[in_progress completed] },
                   metadata: { count_number: @count.count_number,
                               cutoff: cutoff.iso8601(6),
                               physical: @count.items.count(&:physical?),
                               uncounted: @count.items.count { |item| !item.counted? },
                               system_adopted: adopted })
      end
      success
    rescue ActiveRecord::RecordInvalid => e
      failure(record_error_message(e.record))
    rescue AuditLoggable::AuditWriteFailed
      failure(t_error("audit_failed"))
    end

    private

    def adopt_system_quantities!(cutoff)
      legacy  = @count.items.select(&:legacy_unverified?)
      on_hand = on_hand_for(legacy.map(&:product_id))

      legacy.map do |item|
        adopted = on_hand[item.product_id].to_d
        change  = { product_id: item.product_id,
                    legacy_quantity: quantity_string(item.counted_quantity),
                    adopted_quantity: quantity_string(adopted) }
        item.update!(legacy_counted_quantity: item.counted_quantity, counted_quantity: adopted,
                     system_quantity: adopted, baseline_at: cutoff, counted_at: nil,
                     quantity_source: "system")
        change
      end
    end
  end
end
