module Inventory
  # THE operation-permission rule for Stock Transfers — used by
  # StockTransferPolicy (screens) and by every Stock Transfer workflow service,
  # so a console, job or any other caller is held to the same rule. One
  # permission per operation:
  #
  #   view          view_stock_transfers          (list and details)
  #   create        create_stock_transfers        (create / edit a draft, submit it)
  #   approve       approve_stock_transfers       (approve = a decision; a direct transfer also posts)
  #   edit_pending  edit_pending_stock_transfers  (edit a pending transfer's lines and notes)
  #   reject        reject_stock_transfers        (reject a pending transfer)
  #   cancel        cancel_stock_transfers        (cancel a transfer not yet dispatched)
  #   dispatch      dispatch_stock_transfers      (post an approved transfer into transit — source side)
  #   receive       receive_stock_transfers       (receive a transfer in transit — destination side)
  #   resolve       resolve_stock_transfer_discrepancies (return / write off a reported shortfall)
  #
  # Self-approval is allowed: the requester may approve their own transfer
  # when they hold approve_stock_transfers (no separation-of-duties rule).
  #
  # Existing broad permissions keep exactly what they gave before: viewing
  # (view_inventory, manage_inventory, manage_stock_transfers) and creating
  # (manage_inventory, manage_stock_transfers — creating used to post). They
  # NEVER grant approving, editing a pending transfer, rejecting, cancelling,
  # dispatching, receiving or resolving; those need the new permissions,
  # granted explicitly.
  #
  # Voiding an approved transfer keeps its existing rule (StockTransferPolicy#void?).
  #
  # The owner holds every permission (User#can?). Permissions never grant
  # warehouse access; every operation also needs the warehouses it acts on
  # (Inventory::WarehouseReach): both ends, except dispatch (the source) and
  # receipt (the destination).
  module StockTransferAuthorization
    PERMISSIONS = {
      view:         "view_stock_transfers",
      create:       "create_stock_transfers",
      approve:      "approve_stock_transfers",
      edit_pending: "edit_pending_stock_transfers",
      reject:       "reject_stock_transfers",
      cancel:       "cancel_stock_transfers",
      dispatch:     "dispatch_stock_transfers",
      receive:      "receive_stock_transfers",
      resolve:      "resolve_stock_transfer_discrepancies"
    }.freeze

    # Existing permissions honoured for the operation they already covered.
    LEGACY_PERMISSIONS = {
      view:   %w[view_inventory manage_inventory manage_stock_transfers],
      create: %w[manage_inventory manage_stock_transfers]
    }.freeze

    # The pre-workflow rule for reversing a posted transfer — unchanged.
    VOID_PERMISSIONS = %w[manage_inventory manage_stock_transfers].freeze

    module_function

    def permits?(actor, operation)
      key = PERMISSIONS.fetch(operation)
      return false if actor.nil?

      actor.can?(key) || LEGACY_PERMISSIONS.fetch(operation, []).any? { |permission| actor.can?(permission) }
    end

    def permits_void?(actor)
      return false if actor.nil?

      VOID_PERMISSIONS.any? { |permission| actor.can?(permission) }
    end

    # Any transfer operation — the inventory screens admitted without the
    # inventory view (Inventory::StockTransfersController, the product pickers).
    def any?(actor) = PERMISSIONS.keys.any? { |operation| permits?(actor, operation) }

    def message
      I18n.t("inventory.stock_transfers.errors.not_permitted")
    end
  end
end
