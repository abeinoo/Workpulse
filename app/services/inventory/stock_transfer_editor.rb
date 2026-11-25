module Inventory
  # An approver's edit of a PENDING transfer: change line quantities, add or
  # remove products, change the notes. The transfer stays pending_approval —
  # its reservation simply becomes the edited lines, in the same transaction
  # as the edit (the reservation is derived from the lines of a pending
  # transfer, Inventory::StockAvailability):
  #
  #   quantity up / product added   -> reserves the extra, only if available
  #   quantity down / product removed -> releases the difference
  #
  # One transaction: lock the transfer row and re-check pending_approval and
  # the lock_token; re-verify both warehouses FOR SHARE; apply the edit; lock
  # the Product rows (old AND new lines) FOR UPDATE in id order; refuse an
  # Inactive destination pair for the lines; validate the WHOLE edited
  # request against what OTHER documents reserve (its own reservation
  # excluded). If anything is short or invalid, the whole edit rolls back and
  # the previous request — and so its reservation — stays exactly as it was.
  #
  # The warehouses are fixed once submitted (the reservation lives in the
  # source); an edit that changes either end is refused.
  #
  # Enforced here: edit_pending_stock_transfers (legacy broad permissions
  # never grant it) and reach to both warehouses. Drafts are edited through
  # Inventory::StockTransferDraftService.
  #
  # Audit (mandatory, log_audit!): "update_pending" with the before/after
  # lines, the notes change and the per-product reservation change. The
  # original request stays in the "submit_for_approval" entry, never altered.
  class StockTransferEditor
    include AuditLoggable

    PERMITTED = %w[notes items_attributes].freeze

    def initialize(stock_transfer_id:, actor:, attributes:, lock_token: nil)
      @stock_transfer_id = stock_transfer_id
      @actor             = actor
      @attributes        = normalize(attributes)
      @lock_token        = lock_token.presence
    end

    def call
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      unless StockTransferAuthorization.permits?(@actor, :edit_pending)
        return StockTransferWorkflow.failure(transfer, StockTransferAuthorization.message)
      end
      return StockTransferWorkflow.failure(transfer, WarehouseReach.message) unless StockTransferWorkflow.reaches?(@actor, transfer)
      return StockTransferWorkflow.failure(transfer, I18n.t("inventory.stock_transfers.errors.warehouses_fixed")) if warehouse_change?(transfer)
      return StockTransferWorkflow.invalid_transition(transfer) unless transfer.pending_approval?

      error = nil
      ActiveRecord::Base.transaction do
        transfer.lock!
        transfer.items.reset
        error = precondition_error(transfer)
        raise ActiveRecord::Rollback if error
        if (error = StockTransferWorkflow.verify_warehouses_under_lock(@actor, transfer))
          raise ActiveRecord::Rollback
        end

        before       = StockTransferWorkflow.line_snapshot(transfer.items)
        notes_before = transfer.notes
        old_products = transfer.items.map(&:product_id)
        transfer.assign_attributes(@attributes.slice(*PERMITTED))

        StockTransferWorkflow.lock_products!(transfer, old_products)
        guard = IncomingAvailabilityGuard.new(warehouse_id: transfer.destination_warehouse_id,
                                              product_ids: transfer.items.reject(&:marked_for_destruction?).map(&:product_id))
        unless transfer.valid? && !guard.refuse!(transfer) && StockAvailability.validate_transfer!(transfer)
          error = transfer.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end
        transfer.save!
        transfer.touch # advances the lock_token even when only lines changed

        after = StockTransferWorkflow.line_snapshot(transfer.items.reload)
        changes = {}
        changes[:items] = [ before, after ] unless before == after
        changes[:notes] = [ notes_before, transfer.notes ] unless notes_before == transfer.notes
        log_audit!(actor: @actor, auditable: transfer, action: "update_pending", changes: changes,
                   metadata: { reservation_change: StockTransferWorkflow.reservation_delta(before, after) })
      end
      return StockTransferWorkflow.failure(transfer, error) if error

      StockTransferWorkflow.success(transfer)
    rescue ActiveRecord::RecordInvalid => e
      StockTransferWorkflow.failure(transfer, e.record.errors.full_messages.to_sentence)
    rescue ActiveRecord::RecordNotFound => e
      StockTransferWorkflow.failure(transfer, e.message)
    rescue AuditLoggable::AuditWriteFailed
      StockTransferWorkflow.failure(transfer, I18n.t("inventory.stock_transfers.errors.audit_failed"))
    end

    private

    def precondition_error(transfer)
      return I18n.t("inventory.stock_transfers.errors.invalid_transition") unless transfer.pending_approval? && !transfer.voided?
      return nil if @lock_token.nil? || @lock_token == transfer.lock_token

      I18n.t("inventory.stock_transfers.errors.stale_edit")
    end

    def warehouse_change?(transfer)
      %w[source_warehouse_id destination_warehouse_id].any? do |key|
        @attributes.key?(key) && @attributes[key].to_s != transfer.public_send(key).to_s
      end
    end

    def normalize(attributes)
      hash = attributes.respond_to?(:to_unsafe_h) ? attributes.to_unsafe_h : attributes.to_h
      hash.with_indifferent_access
    end
  end
end
