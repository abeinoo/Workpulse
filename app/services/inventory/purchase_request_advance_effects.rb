module Inventory
  # Inventory & Purchasing contract for the financial effects of a Purchase
  # Request advance payment (S2 — module-boundaries.md §14.2 #6, the half Batch S
  # deferred as D-S2). A sibling of Inventory::GoodsReceiptPaymentEffects: there
  # the settleable is a goods receipt, here it is the Purchase Request.
  #
  # The advance, its lifecycle (record-and-fund, reverse, cancel of an old
  # pending one), its row locks, refusals and audits are Inventory &
  # Purchasing's. The settlement ledger, the custody ledger, custody accounts,
  # their balances and who may pay from which account belong to Finance & Sales.
  # Inventory defines WHAT it needs; Finance & Sales implements it and registers
  # the implementation at boot (config/initializers/purchase_request_advance_effects.rb).
  # This module has no dependency on Finance & Sales.
  #
  # The writes are synchronous, in-process and run inside the caller's database
  # transaction — the caller holds the Purchase Request row lock (and, for a
  # reversal, the advance's), and any lock the handler takes comes after them
  # (request → advance → custody account). A handler never opens its own transaction; a write it cannot make
  # raises ActiveRecord::RecordInvalid, so the caller's transaction rolls back as
  # before. Other errors propagate unchanged. Like Batch S (D-S1), the documented
  # event target is deferred in favour of this interface.
  #
  # A handler must respond to:
  #   custody_account_options(actor:)
  #     — the custody accounts `actor` may use as the SOURCE of an employee
  #       custody transfer, for the form: an Array of CustodyAccountOption (id,
  #       holder name, ledger balance), in display order. Read-only.
  #   selectable_custody_account_id(actor:, custody_account_id:)
  #     — `custody_account_id` when it names such a source account, otherwise
  #       nil. Read-only (the recorder refuses the advance on nil).
  #   responsible_employee_options(actor:)
  #     — the employees of `actor`'s business who may be a Purchase Request's
  #       responsible employee (purchasing permission + active custody account):
  #       an Array of ResponsibleEmployeeOption in display order. Read-only.
  #   responsible_custody_account_id(business_id:, user_id:)
  #     — that employee's active custody account id when they are eligible as
  #       the responsible employee, otherwise nil. Read-only.
  #   lock_funding_accounts(business_id:, custody_account_ids:)
  #     — lock (FOR UPDATE, in id order) the custody accounts a funding advance
  #       is about to name, BEFORE the caller inserts the advance: the insert's
  #       foreign keys take key-share locks on them, and taking those first
  #       would let two recordings sharing an account deadlock against
  #       advance_funded's locks. Returns nil.
  #   advance_funded(advance:, actor:)
  #     — the funding advance is being recorded (the advance row is inserted,
  #       in the caller's transaction): lock its accounts, re-check
  #       them (Funding :custody_account_inactive / :employee_ineligible, nothing
  #       written), then post the funding — an employee custody transfer pair
  #       (source −, responsible +) or a company funding credit — and return
  #       Funding(:confirmed, transaction_id: the credit, counterparty_id: the
  #       transfer's source debit or nil). On a refusal the caller rolls the
  #       advance back.
  #   advance_funding_reversed(advance:, actor:, reason:)
  #     — the confirmed funding advance is being reversed: post the opposite
  #       rows. Returns Funding(:confirmed, transaction_id: the responsible-side
  #       debit, counterparty_id: the credit back to the source or nil).
  #   advance_reversed(advance:, actor:, reason:)
  #     — a confirmed LEGACY (supplier-payment) advance is being reversed: post
  #       the equal-and-opposite settlement and, for custody, the linked credit.
  #       Returns a Reversal (the original settlement id and the reversal id).
  module PurchaseRequestAdvanceEffects
    OPERATIONS = %i[custody_account_options selectable_custody_account_id
                    responsible_employee_options responsible_custody_account_id
                    lock_funding_accounts advance_funded advance_funding_reversed advance_reversed].freeze

    FUNDING_STATUSES = %i[confirmed custody_account_inactive employee_ineligible].freeze

    # One account the form offers. `balance` is the ledger balance (SUM of the
    # account's non-voided rows), 0 when it has none.
    CustodyAccountOption = Struct.new(:id, :holder_name, :balance, keyword_init: true)

    # One eligible responsible employee, with their custody account and balance.
    ResponsibleEmployeeOption = Struct.new(:user_id, :name, :custody_account_id, :balance, keyword_init: true)

    Reversal = Struct.new(:settlement_id, :reversal_id, keyword_init: true)

    # The custody rows of one funding (or its reversal): transaction_id is the
    # responsible employee's row, counterparty_id the source employee's
    # transfer leg (nil for company cash / bank).
    Funding = Struct.new(:status, :transaction_id, :counterparty_id, keyword_init: true) do
      def confirmed? = status == :confirmed
    end

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
        checked_options(:custody_account_options, handler.custody_account_options(actor: actor), CustodyAccountOption)
      end

      def selectable_custody_account_id(actor:, custody_account_id:)
        checked_id(:selectable_custody_account_id,
                   handler.selectable_custody_account_id(actor: actor, custody_account_id: custody_account_id))
      end

      def responsible_employee_options(actor:)
        checked_options(:responsible_employee_options, handler.responsible_employee_options(actor: actor),
                        ResponsibleEmployeeOption)
      end

      def responsible_custody_account_id(business_id:, user_id:)
        checked_id(:responsible_custody_account_id,
                   handler.responsible_custody_account_id(business_id: business_id, user_id: user_id))
      end

      def lock_funding_accounts(business_id:, custody_account_ids:)
        result = handler.lock_funding_accounts(business_id: business_id, custody_account_ids: custody_account_ids)
        return nil if result.nil?

        raise ArgumentError, "#{handler}.lock_funding_accounts returned #{result.inspect}, expected nil"
      end

      def advance_funded(advance:, actor:)
        checked_funding(:advance_funded, handler.advance_funded(advance: advance, actor: actor), FUNDING_STATUSES)
      end

      def advance_funding_reversed(advance:, actor:, reason:)
        checked_funding(:advance_funding_reversed,
                        handler.advance_funding_reversed(advance: advance, actor: actor, reason: reason), %i[confirmed])
      end

      def advance_reversed(advance:, actor:, reason:)
        reversal = handler.advance_reversed(advance: advance, actor: actor, reason: reason)
        if reversal.is_a?(Reversal) && reversal.settlement_id.is_a?(Integer) && reversal.reversal_id.is_a?(Integer)
          return reversal
        end

        raise ArgumentError, "#{handler}.advance_reversed returned #{reversal.inspect}, expected a #{Reversal}"
      end

      private

      def checked_options(operation, options, type)
        return options if options.is_a?(Array) && options.all?(type)

        raise ArgumentError, "#{handler}.#{operation} returned #{options.class}, expected an Array of #{type}"
      end

      def checked_id(operation, id)
        return id if id.nil? || id.is_a?(Integer)

        raise ArgumentError, "#{handler}.#{operation} returned #{id.class}, expected Integer or nil"
      end

      # A confirmed Funding names its credit row; the counterparty is an Integer
      # (transfer) or nil (company). A refusal names no row.
      def checked_funding(operation, funding, statuses)
        valid = funding.is_a?(Funding) && statuses.include?(funding.status) &&
                if funding.confirmed?
                  funding.transaction_id.is_a?(Integer) && (funding.counterparty_id.nil? || funding.counterparty_id.is_a?(Integer))
                else
                  funding.transaction_id.nil? && funding.counterparty_id.nil?
                end
        return funding if valid

        raise ArgumentError, "#{handler}.#{operation} returned #{funding.inspect}, expected a " \
                             "#{Funding} with a status in #{statuses.inspect}"
      end
    end
  end
end
