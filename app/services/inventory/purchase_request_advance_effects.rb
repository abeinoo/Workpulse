module Inventory
  # Inventory & Purchasing contract for the financial effects of a Purchase
  # Request advance payment (S2 — module-boundaries.md §14.2 #6, the half Batch S
  # deferred as D-S2). A sibling of Inventory::GoodsReceiptPaymentEffects: there
  # the settleable is a goods receipt, here it is the Purchase Request.
  #
  # The advance, its lifecycle (record, confirm, cancel, reverse), its row locks,
  # refusals, audits and the request's capacity arithmetic are Inventory &
  # Purchasing's. The settlement ledger, the custody ledger, custody accounts,
  # their balances and who may pay from which account belong to Finance & Sales.
  # Inventory defines WHAT it needs; Finance & Sales implements it and registers
  # the implementation at boot (config/initializers/purchase_request_advance_effects.rb).
  # This module has no dependency on Finance & Sales.
  #
  # The writes are synchronous, in-process and run inside the caller's database
  # transaction — the caller holds the Purchase Request and advance row locks, and
  # any lock the handler takes comes after them (request → advance → custody
  # account). A handler never opens its own transaction; a write it cannot make
  # raises ActiveRecord::RecordInvalid, so the caller's transaction rolls back as
  # before. Other errors propagate unchanged. Like Batch S (D-S1), the documented
  # event target is deferred in favour of this interface.
  #
  # A handler must respond to:
  #   custody_account_options(actor:)
  #     — the custody accounts `actor` may pay an advance from, for the form:
  #       an Array of CustodyAccountOption (id, holder name, ledger balance), in
  #       display order. Read-only.
  #   selectable_custody_account_id(actor:, custody_account_id:)
  #     — `custody_account_id` when it names an account `actor` may pay from,
  #       otherwise nil. Read-only (the recorder refuses the advance on nil).
  #   advance_confirmed(advance:, actor:)
  #     — the advance is being confirmed: lock its custody account (if any) and
  #       return Confirmation(:custody_account_inactive) without writing when it
  #       is no longer active; otherwise post the settlement on the Purchase
  #       Request and, for custody, the linked debit, and return
  #       Confirmation(:confirmed, settlement_id).
  #   advance_reversed(advance:, actor:, reason:)
  #     — the confirmed advance is being reversed: post the equal-and-opposite
  #       settlement and, for custody, the linked credit. Returns a Reversal
  #       (the original settlement id and the reversal id).
  module PurchaseRequestAdvanceEffects
    OPERATIONS = %i[custody_account_options selectable_custody_account_id advance_confirmed advance_reversed].freeze

    CONFIRMATION_STATUSES = %i[confirmed custody_account_inactive].freeze

    # One account the form offers. `balance` is the ledger balance (SUM of the
    # account's non-voided rows), 0 when it has none.
    CustodyAccountOption = Struct.new(:id, :holder_name, :balance, keyword_init: true)

    Confirmation = Struct.new(:status, :settlement_id, keyword_init: true) do
      def confirmed? = status == :confirmed
    end

    Reversal = Struct.new(:settlement_id, :reversal_id, keyword_init: true)

    # Raised when an effect is requested before any handler is registered — an
    # advance's money is never silently skipped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Inventory::PurchaseRequestAdvanceEffects handler is registered")
      end

      def custody_account_options(actor:)
        options = handler.custody_account_options(actor: actor)
        return options if options.is_a?(Array) && options.all?(CustodyAccountOption)

        raise ArgumentError, "#{handler}.custody_account_options returned #{options.class}, " \
                             "expected an Array of #{CustodyAccountOption}"
      end

      def selectable_custody_account_id(actor:, custody_account_id:)
        id = handler.selectable_custody_account_id(actor: actor, custody_account_id: custody_account_id)
        return id if id.nil? || id.is_a?(Integer)

        raise ArgumentError, "#{handler}.selectable_custody_account_id returned #{id.class}, expected Integer or nil"
      end

      def advance_confirmed(advance:, actor:)
        confirmation = handler.advance_confirmed(advance: advance, actor: actor)
        valid = confirmation.is_a?(Confirmation) && CONFIRMATION_STATUSES.include?(confirmation.status) &&
                (confirmation.confirmed? ? confirmation.settlement_id.is_a?(Integer) : confirmation.settlement_id.nil?)
        return confirmation if valid

        raise ArgumentError, "#{handler}.advance_confirmed returned #{confirmation.inspect}, expected a " \
                             "#{Confirmation} with a status in #{CONFIRMATION_STATUSES.inspect}"
      end

      def advance_reversed(advance:, actor:, reason:)
        reversal = handler.advance_reversed(advance: advance, actor: actor, reason: reason)
        if reversal.is_a?(Reversal) && reversal.settlement_id.is_a?(Integer) && reversal.reversal_id.is_a?(Integer)
          return reversal
        end

        raise ArgumentError, "#{handler}.advance_reversed returned #{reversal.inspect}, expected a #{Reversal}"
      end
    end
  end
end
