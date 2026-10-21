module Inventory
  # Inventory & Purchasing contract for the financial effects of a goods
  # receipt's payments (Batch S — module-boundaries.md §14.2 #6, write half:
  # settlements whose settleable is a GoodsReceipt).
  #
  # The receipt, its lifecycle (approve, settle, reverse, void), its row lock,
  # its audit rows and the advance-allocation arithmetic are Inventory &
  # Purchasing's. The settlement ledger, the custody ledger, custody accounts and
  # their balances belong to Finance & Sales. Inventory defines WHAT it needs;
  # Finance & Sales implements it and registers the implementation at boot
  # (config/initializers/goods_receipt_payment_effects.rb). This module has no
  # dependency on Finance & Sales.
  #
  # Calls are synchronous, in-process and run inside the caller's database
  # transaction — the caller holds the receipt row lock, and any lock the handler
  # takes comes after it (receipt → purchase request → custody account). A handler
  # never opens its own independent transaction; a write it cannot make raises
  # ActiveRecord::RecordInvalid, so the caller's transaction (and, in approval,
  # its savepoint) rolls back as before. Other errors propagate unchanged. The
  # documented goods_receipt.* event target is deferred in favour of this
  # interface (approved 2026-10-21).
  #
  # A handler must respond to:
  #   custody_account_active?(receipt:)
  #     — is the receipt's funding source an active custody account? true / false.
  #       Read-only (approval refuses an employee-custody receipt otherwise).
  #   approval_payment(receipt:, amount:, actor:)
  #     — the receipt is being approved with `amount` still due after advances:
  #       pay it from the receipt's funding (employee custody: the receipt's
  #       custody account, debited; company cash / bank account: no account;
  #       supplier credit: nothing). Nothing for a zero amount. Returns nil.
  #   advance_applied(receipt:, advance:, amount:, actor:, reference:, notes:)
  #     — record `amount` of a confirmed purchase-request advance as applied to
  #       the receipt (computed by Inventory). Moves no money. Returns nil.
  #   payment_source_kind?(source_kind)
  #     — is `source_kind` a way of paying a receipt later? true / false.
  #   payer_custody_account_id(actor:)
  #     — the id of the custody account `actor` may pay from (their own, active),
  #       or nil. Read-only.
  #   record_settlement(receipt:, actor:, source_kind:, custody_account_id:, amount:, reference:, notes:, settled_at:)
  #     — record one later payment; with a custody account id, lock that account
  #       and debit it. Returns a Payment.
  #   reverse_settlement(receipt:, settlement_id:, actor:, reason:)
  #     — reverse ONE of the receipt's settlements: find it under a row lock
  #       (ActiveRecord::RecordNotFound when it is not the receipt's), refuse it
  #       when it is a reversal or already reversed (:already_reversed) or an
  #       advance application (:advance_application), otherwise post the
  #       equal-and-opposite settlement and, for a custody payment, credit the
  #       account. Returns a Reversal.
  #   reverse_all(receipt:, actor:, notes:)
  #     — the receipt is being voided: reverse every settlement still in effect,
  #       crediting custody for each custody payment reversed. Returns nil.
  module GoodsReceiptPaymentEffects
    OPERATIONS = %i[
      custody_account_active? approval_payment advance_applied payment_source_kind? payer_custody_account_id
      record_settlement reverse_settlement reverse_all
    ].freeze

    REVERSAL_STATUSES = %i[reversed already_reversed advance_application].freeze

    # A recorded later payment. `settlement` is returned opaquely, for the
    # recorder's Result only; Inventory reads the scalar fields (its audit).
    Payment = Struct.new(:settlement, :settlement_id, :reference, :custody_account_id, :employee_id,
                         keyword_init: true)

    # The outcome of reverse_settlement. On :reversed, `settlement` (opaque, for the
    # reverser's Result) is the new reversal; the scalar fields describe the
    # original (its id, amount, source kind, funding source id) and the reversal id.
    Reversal = Struct.new(:status, :settlement, :settlement_id, :reversal_id, :amount, :source_kind, :funding_source_id,
                          keyword_init: true) do
      def reversed? = status == :reversed
    end

    # Raised when an effect is requested before any handler is registered —
    # a goods-receipt payment is never silently skipped.
    class NotRegistered < StandardError; end

    class << self
      def register(handler)
        missing = OPERATIONS.reject { |operation| handler.respond_to?(operation) }
        raise ArgumentError, "#{handler} does not implement #{missing.join(', ')}" if missing.any?

        @handler = handler
      end

      def handler
        @handler || raise(NotRegistered, "No Inventory::GoodsReceiptPaymentEffects handler is registered")
      end

      def custody_account_active?(receipt:)
        boolean(:custody_account_active?, handler.custody_account_active?(receipt: receipt))
      end

      def approval_payment(receipt:, amount:, actor:)
        handler.approval_payment(receipt: receipt, amount: amount, actor: actor)
        nil
      end

      def advance_applied(receipt:, advance:, amount:, actor:, reference:, notes:)
        handler.advance_applied(receipt: receipt, advance: advance, amount: amount, actor: actor,
                                reference: reference, notes: notes)
        nil
      end

      def payment_source_kind?(source_kind)
        boolean(:payment_source_kind?, handler.payment_source_kind?(source_kind))
      end

      def payer_custody_account_id(actor:)
        id = handler.payer_custody_account_id(actor: actor)
        return id if id.nil? || id.is_a?(Integer)

        raise ArgumentError, "#{handler}.payer_custody_account_id returned #{id.class}, expected Integer or nil"
      end

      def record_settlement(receipt:, actor:, source_kind:, custody_account_id:, amount:, reference:, notes:, settled_at:)
        payment = handler.record_settlement(receipt: receipt, actor: actor, source_kind: source_kind,
                                            custody_account_id: custody_account_id, amount: amount,
                                            reference: reference, notes: notes, settled_at: settled_at)
        return payment if payment.is_a?(Payment)

        raise ArgumentError, "#{handler}.record_settlement returned #{payment.class}, expected #{Payment}"
      end

      def reverse_settlement(receipt:, settlement_id:, actor:, reason:)
        reversal = handler.reverse_settlement(receipt: receipt, settlement_id: settlement_id, actor: actor, reason: reason)
        unless reversal.is_a?(Reversal) && REVERSAL_STATUSES.include?(reversal.status)
          raise ArgumentError, "#{handler}.reverse_settlement returned #{reversal.inspect}, expected a #{Reversal} " \
                               "with a status in #{REVERSAL_STATUSES.inspect}"
        end

        reversal
      end

      def reverse_all(receipt:, actor:, notes:)
        handler.reverse_all(receipt: receipt, actor: actor, notes: notes)
        nil
      end

      private

      def boolean(operation, value)
        return value if value == true || value == false

        raise ArgumentError, "#{handler}.#{operation} returned #{value.class}, expected true or false"
      end
    end
  end
end
