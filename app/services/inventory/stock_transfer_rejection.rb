module Inventory
  # pending_approval -> rejected. Releases the transfer's reservation by that
  # status change (Inventory::StockAvailability) and moves no stock.
  #
  # The row is locked and its status re-checked inside the transaction, so a
  # repeated request — or a rejection racing an approval or cancellation —
  # can't release twice or reject a transfer that has just been posted.
  # Releasing only frees stock, so no product lock is needed.
  #
  # Enforced here: reject_stock_transfers (legacy broad permissions never
  # grant it), reach to both warehouses, and a reason. Rejecting stays
  # possible after a warehouse was deactivated. The "reject" audit entry is
  # mandatory (log_audit!).
  class StockTransferRejection
    include AuditLoggable

    def initialize(stock_transfer_id:, actor:, reason:)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
      @reason            = reason.to_s.strip
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :reject)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      return StockTransferWorkflow.failure(transfer, WarehouseReach.message) unless StockTransferWorkflow.reaches?(@actor, transfer)
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.pending_approval?

      if @reason.blank?
        transfer.errors.add(:rejection_reason, :blank)
        return StockTransferWorkflow.failure(transfer, transfer.errors.full_messages.to_sentence)
      end

      error = nil
      transfer.with_lock do
        unless transfer.pending_approval? && !transfer.voided?
          error = I18n.t("inventory.stock_transfers.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end

        released = StockTransferWorkflow.quantity_totals(transfer)
        transfer.status           = :rejected
        transfer.rejected_by      = @actor
        transfer.rejected_at      = Time.current
        transfer.rejection_reason = @reason
        transfer.save!
        log_audit!(actor: @actor, auditable: transfer, action: "reject",
                   changes: { status: [ "pending_approval", "rejected" ] },
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
