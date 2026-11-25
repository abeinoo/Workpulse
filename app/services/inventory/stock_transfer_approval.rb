module Inventory
  # Approves a pending transfer. Approval is a DECISION, never a stock movement
  # for a via-transit transfer (D1):
  #
  #   via_transit  pending_approval -> awaiting_dispatch. Nothing moves; the
  #                reservation stays (Inventory::StockAvailability) until the
  #                source side dispatches it (Inventory::StockTransferDispatch)
  #                or it is cancelled.
  #   direct       pending_approval -> approved, posting source OUT +
  #                destination IN at once (Inventory::StockTransferPoster) —
  #                the behaviour such transfers always had, kept unchanged (D11).
  #
  # In one transaction: lock the transfer row, reload its lines and re-check
  # pending_approval (a repeated or concurrent approval sees the new status and
  # refuses); re-verify both warehouses FOR SHARE (active, reached); lock the
  # Product rows FOR UPDATE in id order; re-validate availability against what
  # OTHER documents reserve (this transfer's own reservation excluded) and the
  # destination's availability rows; record approver and time; write the
  # mandatory "approve" audit entry with the approved quantities. Any failure
  # rolls everything back.
  #
  # The lines approved are the CURRENT lines — the final version after any
  # approver edits (Inventory::StockTransferEditor, same row lock).
  #
  # Enforced here: approve_stock_transfers (legacy broad permissions never
  # grant it) and reach to BOTH warehouses. Self-approval is allowed.
  class StockTransferApproval
    include AuditLoggable

    def initialize(stock_transfer_id:, actor:)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :approve)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      return StockTransferWorkflow.failure(transfer, WarehouseReach.message) unless StockTransferWorkflow.reaches?(@actor, transfer)
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.pending_approval?

      error = nil
      ActiveRecord::Base.transaction do
        transfer.lock!
        transfer.items.reset # never approve lines loaded before the lock
        unless transfer.pending_approval? && !transfer.voided?
          error = I18n.t("inventory.stock_transfers.errors.invalid_transition")
          raise ActiveRecord::Rollback
        end
        if (error = StockTransferWorkflow.verify_warehouses_under_lock(@actor, transfer))
          raise ActiveRecord::Rollback
        end

        StockTransferWorkflow.lock_products!(transfer)
        error = transfer.via_transit? ? approve_for_dispatch(transfer) : approve_direct(transfer)
        raise ActiveRecord::Rollback if error
      end
      return StockTransferWorkflow.failure(reset(transfer), error) if error

      StockTransferWorkflow.success(transfer)
    rescue ActiveRecord::RecordInvalid => e
      StockTransferWorkflow.failure(reset(transfer), e.record.errors.full_messages.to_sentence)
    rescue AuditLoggable::AuditWriteFailed
      StockTransferWorkflow.failure(reset(transfer), I18n.t("inventory.stock_transfers.errors.audit_failed"))
    end

    private

    # via_transit: the decision only — re-validated, nothing posted.
    def approve_for_dispatch(transfer)
      guard = IncomingAvailabilityGuard.new(warehouse_id: transfer.destination_warehouse_id,
                                            product_ids: transfer.items.map(&:product_id))
      return transfer.errors.full_messages.to_sentence if guard.refuse!(transfer)
      return transfer.errors.full_messages.to_sentence unless StockAvailability.validate_transfer!(transfer)

      transfer.status      = :awaiting_dispatch
      transfer.approved_by = @actor
      transfer.approved_at = Time.current
      transfer.save!
      log_audit!(actor: @actor, auditable: transfer, action: "approve",
                 changes: { status: [ "pending_approval", "awaiting_dispatch" ] },
                 metadata: common_metadata(transfer).merge(
                   posting_mode: "via_transit", reservation_kept: StockTransferWorkflow.quantity_totals(transfer)
                 ))
      nil
    end

    # direct: the unchanged immediate posting (D11).
    def approve_direct(transfer)
      posted_on = BusinessDay.current(context: transfer.business)
      poster    = StockTransferPoster.new(transfer, posted_on: posted_on)
      return transfer.errors.full_messages.to_sentence unless poster.post!

      requested_on = transfer.transferred_on
      transfer.status         = :approved
      transfer.approved_by    = @actor
      transfer.approved_at    = Time.current
      transfer.transferred_on = posted_on
      transfer.save!
      log_audit!(actor: @actor, auditable: transfer, action: "approve",
                 changes: { status: [ "pending_approval", "approved" ],
                            transferred_on: [ requested_on.iso8601, posted_on.iso8601 ] }.reject { |_, (a, b)| a == b },
                 metadata: common_metadata(transfer).merge(
                   posting_mode: "direct", posted_on: posted_on.iso8601,
                   reservation_consumed: StockTransferWorkflow.quantity_totals(transfer), movement_ids: poster.movement_ids
                 ))
      nil
    end

    def common_metadata(transfer)
      {
        transfer_number:          transfer.transfer_number,
        source_warehouse_id:      transfer.source_warehouse_id,
        destination_warehouse_id: transfer.destination_warehouse_id,
        self_approval:            transfer.submitted_by_id == @actor.id,
        # The final approved quantities.
        approved_lines: transfer.items.map do |i|
          { product_id: i.product_id, quantity: QuantityFormat.plain(i.quantity), unit_cost: i.unit_cost.to_d.to_s("F") }
        end
      }
    end

    # Back to what the database holds (the rollback undid the writes).
    def reset(transfer)
      transfer.reload if transfer&.persisted?
      transfer
    end
  end
end
