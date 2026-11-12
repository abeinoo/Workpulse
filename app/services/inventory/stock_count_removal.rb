module Inventory
  # Decision D4 — removing a stock count:
  #
  #   draft / in_progress, never posted  → #delete! (hard delete, items cascade)
  #   in_progress, previously posted     → #cancel! only (a reopened count whose
  #                                         adjustments — even voided — must keep
  #                                         pointing at it)
  #   completed / approved / cancelled   → neither
  #
  # Neither ever touches inventory: a never-posted count has no movements, and a
  # reopened count's adjustment was already reversed by the reopen. A reason is
  # required for both. The count row is locked and re-checked inside the
  # transaction, so a repeated or concurrent request is refused cleanly.
  #
  # The hard delete is audited fail-closed (log_audit!) — the audit entry, with
  # a snapshot of the count, is the only record left of it.
  class StockCountRemoval
    include StockCountService

    def initialize(stock_count_id:, actor:, reason:)
      @stock_count_id = stock_count_id
      @actor          = actor
      @reason         = reason.to_s.strip
    end

    def delete!
      run do
        next t_error("not_deletable") unless @count.deletable?

        log_audit!(actor: @actor, auditable: @count, action: "delete", metadata: snapshot)
        @count.destroy!
        nil
      end
    end

    def cancel!
      run do
        next t_error("not_cancellable") unless @count.cancellable?

        from = @count.status
        @count.update!(status: :cancelled, cancelled_at: Time.current, cancelled_by: @actor,
                       cancel_reason: @reason)
        log_audit!(actor: @actor, auditable: @count, action: "cancel",
                   changes: { status: [ from, "cancelled" ] },
                   metadata: { count_number: @count.count_number, reason: @reason })
        nil
      end
    end

    private

    # Yields under the count's lock; the block returns nil to commit or an
    # error message to abort (nothing written).
    def run
      @error = nil
      if @reason.blank?
        @count = scoped_counts.find(@stock_count_id)
        return failure(t_error("removal_reason_required"))
      end

      ActiveRecord::Base.transaction do
        lock_count!
        @error = yield
        raise ActiveRecord::Rollback if @error
      end
      @error ? failure(@error) : success
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    rescue ImmutableDocument::DeletionNotAllowedError, ActiveRecord::DeleteRestrictionError,
           ActiveRecord::InvalidForeignKey
      failure(t_error("not_deletable"))
    rescue AuditLoggable::AuditWriteFailed
      failure(t_error("audit_failed"))
    end

    def snapshot
      counted = @count.items.select(&:counted?)
      {
        count_number: @count.count_number,
        reason:       @reason,
        status:       @count.status,
        warehouse_id: @count.warehouse_id,
        counted_on:   @count.counted_on.to_s,
        created_by_id: @count.created_by_id,
        products:     @count.items.size,
        counted:      counted.map { |i| { product_id: i.product_id, counted_quantity: quantity_string(i.counted_quantity),
                                          system_quantity: quantity_string(i.system_quantity),
                                          source: i.quantity_source || "legacy" } }
      }
    end
  end
end
