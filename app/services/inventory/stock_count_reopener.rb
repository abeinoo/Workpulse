module Inventory
  # Sends a stock count back to in_progress for recounting.
  #
  #   completed → in_progress  nothing was posted; nothing to reverse.
  #   approved  → in_progress  decision D3: the count's ACTIVE adjustment is
  #                            voided through Inventory::DocumentVoider — the
  #                            original adjustment and its movements stay, and
  #                            compensating "reversal" movements undo exactly its
  #                            stock effect against the CURRENT ledger. No
  #                            snapshot is restored, so receipts, issues and
  #                            transfers after the approval are untouched. If
  #                            the reversal would drive a warehouse negative
  #                            (e.g. an overage was since issued out) the reopen
  #                            is refused and nothing changes. A reason is
  #                            required (it becomes the void reason).
  #
  # The counted quantities, their count times and baselines are kept, so the
  # counter edits only what needs recounting; the next approval posts a NEW
  # adjustment from the then-current differences. Every approval, reversal and
  # reopen stays on record (voided adjustments + audit trail).
  #
  # Idempotent: the count row is locked and its status re-checked inside the
  # transaction; a second (or concurrent) reopen finds it in_progress and is
  # refused, so an adjustment is never reversed twice (DocumentVoider also
  # refuses an already-voided document under its own row lock).
  #
  # A pre-repair approved count whose adjustment is not linked through
  # stock_adjustments.stock_count_id is refused (see #unlinked_legacy_adjustment?).
  class StockCountReopener
    include StockCountService

    def initialize(stock_count_id:, actor:, reason: nil)
      @stock_count_id = stock_count_id
      @actor          = actor
      @reason         = reason.to_s.strip
    end

    def call
      @error = nil
      ActiveRecord::Base.transaction do
        lock_count!
        from = @count.status
        @error = precondition_error
        raise ActiveRecord::Rollback if @error

        reversed = (reverse_active_adjustment! if @count.approved?)
        raise ActiveRecord::Rollback if @error

        @count.update!(status: :in_progress, completed_at: nil, completed_by: nil,
                       approved_at: nil, approved_by: nil)
        log_audit!(actor: @actor, auditable: @count, action: "reopen",
                   changes: { status: [ from, "in_progress" ] },
                   metadata: { count_number: @count.count_number, reason: @reason.presence,
                               reversed_adjustment_id: reversed&.id,
                               reversed_adjustment_number: reversed&.adjustment_number }.compact)
      end
      @error ? failure(@error) : success
    rescue ActiveRecord::RecordInvalid => e
      failure(e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      failure(t_error("audit_failed"))
    end

    private

    def precondition_error
      return t_error("not_reopenable") unless @count.completed? || @count.approved?
      return t_error("reopen_reason_required") if @count.approved? && @reason.blank?
      return t_error("legacy_link_unresolved") if unlinked_legacy_adjustment?

      nil
    end

    # An approved pre-repair count whose adjustment the backfill could not link
    # unambiguously (stock_adjustments.stock_count_id): reopening would leave
    # that adjustment in effect and a re-approval would apply the count twice,
    # so it is refused until the link is reconciled manually.
    def unlinked_legacy_adjustment?
      return false unless @count.approved?

      legacy = @count.legacy_stock_adjustment
      legacy.present? && legacy.active? && legacy.stock_count_id != @count.id
    end

    # Approved with no adjustment (a perfect count) has nothing to reverse.
    def reverse_active_adjustment!
      adjustment = @count.stock_adjustments.active.first
      return nil if adjustment.nil?

      result = DocumentVoider.new(adjustment, user: @actor, reason: @reason,
                                  audit: true, stock_count_reopen: true).call
      return adjustment if result.ok?

      @error = adjustment.errors.full_messages.to_sentence.presence || t_error("reopen_failed")
      nil
    end
  end
end
