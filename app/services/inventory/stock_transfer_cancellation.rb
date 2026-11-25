module Inventory
  # draft / pending_approval / awaiting_dispatch -> cancelled. None of them has
  # posted a movement, so cancellation never touches stock; cancelling a
  # pending or approved-but-not-dispatched transfer releases its reservation by
  # that status change (Inventory::StockAvailability).
  #
  # Never after dispatch (D5): a dispatched transfer is received or resolved
  # (Inventory::StockTransferDiscrepancyResolution); a direct transfer that was
  # posted is reversed only through the existing void (Inventory::DocumentVoider).
  # Drafts are cancelled, never deleted, so every reference stays traceable.
  #
  # The row is locked and its status re-checked inside the transaction, so a
  # repeated request, or a cancellation racing an approval, can't release
  # twice or cancel a transfer that has just been posted.
  #
  # Enforced here: cancel_stock_transfers (legacy broad permissions never
  # grant it), reach to both warehouses, and a reason. The "cancel" audit
  # entry is mandatory (log_audit!).
  class StockTransferCancellation
    include AuditLoggable

    def initialize(stock_transfer_id:, actor:, reason:)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
      @reason            = reason.to_s.strip
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :cancel)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      return StockTransferWorkflow.failure(transfer, WarehouseReach.message) unless StockTransferWorkflow.reaches?(@actor, transfer)
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.cancellable?

      if @reason.blank?
        transfer.errors.add(:cancellation_reason, :blank)
        return StockTransferWorkflow.failure(transfer, transfer.errors.full_messages.to_sentence)
      end

      error = nil
      transfer.with_lock do
        unless transfer.cancellable?
          error = I18n.t("inventory.stock_transfers.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end

        from_status = transfer.status
        released    = StockTransfer::RESERVING_STATUSES.include?(from_status) ? StockTransferWorkflow.quantity_totals(transfer) : {}
        transfer.status              = :cancelled
        transfer.cancelled_by        = @actor
        transfer.cancelled_at        = Time.current
        transfer.cancellation_reason = @reason
        transfer.save!
        log_audit!(actor: @actor, auditable: transfer, action: "cancel",
                   changes: { status: [ from_status, "cancelled" ] },
                   metadata: { reason: @reason, reservation_released: released })
      end
      return StockTransferWorkflow.failure(transfer.reload, error) if error

      StockTransferWorkflow.success(transfer)
    rescue ActiveRecord::RecordInvalid => e
      StockTransferWorkflow.failure(transfer.reload, e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      StockTransferWorkflow.failure(transfer.reload, I18n.t("inventory.stock_transfers.errors.audit_failed"))
    end
  end
end
