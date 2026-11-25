module Inventory
  # draft -> pending_approval. Submitting RESERVES the requested quantities in
  # the source warehouse — the reservation is this status itself
  # (Inventory::StockAvailability) — and moves no stock.
  #
  # One transaction: lock the transfer row and re-check it is a draft;
  # re-verify both warehouses FOR SHARE (active, reached); lock the Product
  # rows FOR UPDATE in id order; refuse an Inactive destination pair
  # (IncomingAvailabilityGuard); validate that every product is available
  # after what OTHER documents reserve (approved stock issues, pending
  # transfers); then record the submitter, time and status. Two concurrent
  # submissions of the same stock serialize on the product locks, and the
  # second sees the first's reservation — the last units can't be reserved
  # twice. Any failure leaves the draft exactly as it was.
  #
  # Enforced here: create_stock_transfers (submitting is part of creating)
  # and reach to both warehouses.
  #
  # Audit (mandatory, log_audit!): "submit_for_approval" with the ORIGINAL
  # REQUEST snapshot — the lines as submitted — which later approver edits
  # never alter. If it can't be written the submission rolls back.
  class StockTransferSubmission
    include AuditLoggable

    def initialize(stock_transfer_id:, actor:)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :create)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      return StockTransferWorkflow.failure(transfer, WarehouseReach.message) unless StockTransferWorkflow.reaches?(@actor, transfer)
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.draft?

      error = nil
      ActiveRecord::Base.transaction do
        transfer.lock!
        transfer.items.reset
        unless transfer.draft? && !transfer.voided?
          error = I18n.t("inventory.stock_transfers.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end
        if (error = StockTransferWorkflow.verify_warehouses_under_lock(@actor, transfer))
          raise ActiveRecord::Rollback
        end

        StockTransferWorkflow.lock_products!(transfer)
        guard = IncomingAvailabilityGuard.new(warehouse_id: transfer.destination_warehouse_id,
                                              product_ids: transfer.items.map(&:product_id))
        if guard.refuse!(transfer) || !StockAvailability.validate_transfer!(transfer)
          error = transfer.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end

        # The original request, per line (D9): fixed at submission, never
        # changed by later approver edits (which change only `quantity`).
        transfer.items.each { |item| item.update!(requested_quantity: item.quantity) }
        transfer.status       = :pending_approval
        transfer.submitted_by = @actor
        transfer.submitted_at = Time.current
        transfer.save!
        log_audit!(actor: @actor, auditable: transfer, action: "submit_for_approval",
                   changes: { status: [ "draft", "pending_approval" ] },
                   metadata: { requested_lines: StockTransferWorkflow.line_snapshot(transfer.items),
                               reserved: StockTransferWorkflow.quantity_totals(transfer),
                               source_warehouse_id: transfer.source_warehouse_id,
                               destination_warehouse_id: transfer.destination_warehouse_id })
      end
      return restore(transfer, error) if error

      StockTransferWorkflow.success(transfer)
    rescue ActiveRecord::RecordInvalid => e
      restore(transfer, e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      restore(transfer, I18n.t("inventory.stock_transfers.errors.audit_failed"))
    end

    private

    # The in-memory record goes back to what the database holds.
    def restore(transfer, error)
      transfer.status = transfer.status_in_database if transfer.persisted?
      %w[submitted_by_id submitted_at].each { |attr| transfer[attr] = transfer.attribute_in_database(attr) }
      StockTransferWorkflow.failure(transfer, error)
    end
  end
end
