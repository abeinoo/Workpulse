module Inventory
  # Creates a NEW draft stock transfer, or saves edits to an existing DRAFT.
  # A draft reserves nothing and moves nothing — stock is reserved only at
  # submission (Inventory::StockTransferSubmission) and moves only at approval
  # (Inventory::StockTransferApproval).
  #
  # Enforced here, whoever the caller: create_stock_transfers (or a legacy
  # permission that already allowed creating — StockTransferAuthorization) and
  # reach to BOTH warehouses; each warehouse id comes from the caller and is
  # re-checked, never trusted. The model refuses inactive warehouses, the same
  # warehouse twice, and warehouses or products of another business.
  #
  # The transfer reference (TRF-…) is assigned when the draft is created. The
  # date is not taken from the request: a draft carries the current Business
  # Day until approval sets the posting Business Day (BusinessDay.current —
  # never Date.current).
  #
  # Edits lock the draft row and re-check that it is still a draft, so an edit
  # can't land on a transfer that was just submitted or cancelled; a stale
  # lock_token (someone saved since the form was opened) is refused.
  #
  # Audit: "create" with the requested lines; "update" with before/after
  # lines and changed header fields.
  class StockTransferDraftService
    include AuditLoggable

    Result = StockTransferWorkflow::Result

    # Only these come from the request; status, dates, numbers and actors are
    # the workflow's.
    PERMITTED = %w[source_warehouse_id destination_warehouse_id notes items_attributes].freeze

    def initialize(actor:, attributes:, stock_transfer_id: nil, lock_token: nil)
      @actor             = actor
      @attributes        = normalize(attributes)
      @stock_transfer_id = stock_transfer_id
      @lock_token        = lock_token.presence
    end

    def call
      @stock_transfer_id ? update_draft : create_draft
    end

    private

    def create_draft
      transfer = @actor.business.stock_transfers.build
      transfer.assign_attributes(@attributes)
      transfer.created_by   = @actor
      transfer.status       = :draft
      # Every new transfer goes through the system transit warehouse (D1/D2):
      # approval, then dispatch, then receipt. Existing transfers stay direct (D11).
      transfer.posting_mode = "via_transit"
      return refuse(transfer, StockTransferAuthorization.message) unless StockTransferAuthorization.permits?(@actor, :create)
      return refuse(transfer, WarehouseReach.message) unless requested_warehouses_reachable?(transfer)

      saved = false
      ActiveRecord::Base.transaction do
        transfer.transferred_on  = BusinessDay.current(context: transfer.business)
        transfer.transfer_number = NumberSequencer.new(transfer.business, :stock_transfer).next_number
        raise ActiveRecord::Rollback unless transfer.save

        log_audit(actor: @actor, auditable: transfer, action: "create",
                  metadata: header(transfer).merge(lines: StockTransferWorkflow.line_snapshot(transfer.items)))
        saved = true
      end
      unless saved
        transfer.transfer_number = nil
        return Result.new(ok: false, transfer: transfer, error: transfer.errors.full_messages.to_sentence)
      end

      StockTransferWorkflow.success(transfer)
    end

    def update_draft
      transfer = StockTransferWorkflow.find(@actor, @stock_transfer_id)
      return refuse(transfer, StockTransferAuthorization.message) unless StockTransferAuthorization.permits?(@actor, :create)
      return refuse(transfer, WarehouseReach.message) unless StockTransferWorkflow.reaches?(@actor, transfer)

      error = nil
      ActiveRecord::Base.transaction do
        transfer.lock!
        transfer.items.reset
        error = precondition_error(transfer)
        raise ActiveRecord::Rollback if error

        before        = StockTransferWorkflow.line_snapshot(transfer.items)
        header_before = header(transfer)
        transfer.assign_attributes(@attributes)
        unless requested_warehouses_reachable?(transfer)
          error = WarehouseReach.message
          raise ActiveRecord::Rollback
        end
        unless transfer.save
          error = transfer.errors.full_messages.to_sentence
          raise ActiveRecord::Rollback
        end
        transfer.touch # advances the lock_token even when only lines changed

        after = StockTransferWorkflow.line_snapshot(transfer.items.reload)
        changes = header_before.to_h { |k, v| [ k, [ v, header(transfer)[k] ] ] }.reject { |_, (a, b)| a == b }
        changes[:items] = [ before, after ] unless before == after
        log_audit(actor: @actor, auditable: transfer, action: "update", changes: changes)
      end

      error ? StockTransferWorkflow.failure(transfer, error) : StockTransferWorkflow.success(transfer)
    rescue ActiveRecord::RecordNotFound => e
      StockTransferWorkflow.failure(transfer, e.message)
    end

    def precondition_error(transfer)
      return I18n.t("inventory.stock_transfers.errors.not_editable") unless transfer.draft? && !transfer.voided?
      return nil if @lock_token.nil? || @lock_token == transfer.lock_token

      I18n.t("inventory.stock_transfers.errors.stale_edit")
    end

    # Both requested ends (as far as given) must be warehouses of the actor's
    # business that the actor reaches. Missing ends are left to the model's
    # presence validation.
    def requested_warehouses_reachable?(transfer)
      ids = [ transfer.source_warehouse_id, transfer.destination_warehouse_id ].compact
      ids.empty? || WarehouseReach.permits?(@actor, *ids)
    end

    def header(transfer)
      { source_warehouse_id: transfer.source_warehouse_id, destination_warehouse_id: transfer.destination_warehouse_id,
        notes: transfer.notes }
    end

    def normalize(attributes)
      hash = attributes.respond_to?(:to_unsafe_h) ? attributes.to_unsafe_h : attributes.to_h
      hash.with_indifferent_access.slice(*PERMITTED)
    end

    def refuse(transfer, message)
      transfer.errors.add(:base, message)
      StockTransferWorkflow.failure(transfer, message)
    end
  end
end
