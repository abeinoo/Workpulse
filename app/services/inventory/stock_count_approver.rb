module Inventory
  # completed → approved: posts ONE stock-count Inventory Adjustment from the
  # non-zero differences, through the normal adjustment path (ledger
  # movements, cost recompute, audit, voidable only by reopening the count).
  #
  # Decision D2 — each line posts counted − ledger on-hand AT THAT PRODUCT'S
  # COUNT TIME (StockCountItem#difference, fixed when the quantity was entered
  # or, for system-derived rows, at completion). Live stock is NOT re-read, so
  # a receipt, issue, transfer or adjustment committed after the count stays
  # in effect: e.g. counted 3 of 4, then +10 received → adjustment −1, final 13.
  # If later movements already took more stock than the count leaves, the
  # adjustment is refused (AdjustmentPoster's insufficient-stock check) and
  # nothing is written.
  #
  # Idempotency and concurrency: the count row is locked and its status and
  # active adjustment re-checked inside the transaction, so a double click or
  # two approvers can only ever produce one adjustment; the partial unique
  # index (one active adjustment per count) is the database backstop, and
  # AdjustmentPoster locks the products before its stock check.
  #
  # Segregation of duties (decision D1): whoever ran or submitted the count may
  # not approve it — except the business owner, whose self-approval is allowed
  # and recorded as an explicit exception on the audit entry.
  #
  # A count completed before per-product count times existed still holds
  # legacy rows; it must be reopened and completed again (decision D9 adopts
  # the system quantity for every row not recounted) before it can be approved.
  class StockCountApprover
    include StockCountService

    def initialize(stock_count_id:, actor:)
      @stock_count_id = stock_count_id
      @actor          = actor
    end

    def call
      @error = nil
      ActiveRecord::Base.transaction do
        lock_count!
        @error = precondition_error
        raise ActiveRecord::Rollback if @error

        owner_exception = own_count?
        adjustment = post_adjustment!
        raise ActiveRecord::Rollback if @error

        @count.update!(status: :approved, approved_at: Time.current, approved_by: @actor)
        log_audit!(actor: @actor, auditable: @count, action: "approve",
                   changes: { status: %w[completed approved] },
                   metadata: approval_metadata(adjustment, owner_exception))
      end
      @error ? failure(@error) : success
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotUnique
      failure(t_error("already_approved"))
    rescue AuditLoggable::AuditWriteFailed
      failure(t_error("audit_failed"))
    end

    private

    def precondition_error
      return t_error("not_completed") unless @count.completed?
      return Approvals::SelfApproval.error_message if own_count? && !@actor.owner?
      return t_error("legacy_requires_recompletion", count: @count.legacy_items.size) if @count.legacy_items?
      return t_error("already_approved") if @count.stock_adjustments.active.exists?

      nil
    end

    # The count's "requester": whoever ran it (created_by) or submitted it
    # (completed_by).
    def own_count?
      Approvals::SelfApproval.by_requester?(approver: @actor, requester: @count.completed_by_id) ||
        Approvals::SelfApproval.by_requester?(approver: @actor, requester: @count.created_by_id)
    end

    # Only counted rows with a real variance generate an adjustment line.
    # Uncounted (blank) rows are left untouched — never treated as a zero
    # count. A perfect count approves with no adjustment.
    def post_adjustment!
      diff_items = @count.items.select { |item| item.counted? && item.difference.to_d.nonzero? }
      return nil if diff_items.empty?

      adjustment = @count.business.stock_adjustments.build(
        warehouse:   @count.warehouse,
        stock_count: @count,
        adjusted_on: @count.counted_on,
        reason:      :stock_count,
        created_by:  @actor,
        notes:       I18n.t("inventory.stock_counts.adjustment_note", number: @count.count_number)
      )
      diff_items.each do |item|
        adjustment.items.build(product: item.product, quantity_difference: item.difference)
      end

      result = AdjustmentPoster.new(adjustment).call
      return adjustment if result.ok?

      @error = adjustment.errors.full_messages.to_sentence.presence || t_error("approve_failed")
      nil
    end

    def approval_metadata(adjustment, owner_exception)
      {
        count_number:        @count.count_number,
        adjustment_id:       adjustment&.id,
        adjustment_number:   adjustment&.adjustment_number,
        owner_self_approval: owner_exception,
        self_approval_exception: (owner_exception ? "business_owner" : nil),
        lines: adjustment ? adjustment.items.map { |i| { product_id: i.product_id, quantity_difference: quantity_string(i.quantity_difference) } } : []
      }.compact
    end
  end
end
