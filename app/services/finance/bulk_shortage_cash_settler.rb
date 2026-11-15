module Finance
  # Bulk settlement destination 2 (see Finance::BulkShortageSettlement): "Receive
  # Cash". Reuses the existing shortage Receive mechanism — the same append-only
  # "settlement" ledger row RemainingDepositBalanceSettler writes from the
  # shortage page — labelled with the business's active Cash payment method
  # (settlement_type "cash"), one row per shortage for its full remaining amount.
  #
  # Scope of what is recorded: WorkPulse has no cash drawer or cash receipt
  # ledger, so this records the settlement with the Cash payment method ONLY —
  # it does not (and cannot) update any drawer balance. No custody credit, no
  # TillDeposit and no till session amount is created.
  #
  # Extra guards: the dedicated receive_shortage_settlement_cash permission
  # (bulk only — the single-shortage Receive form is unchanged); the payment
  # method is an active Cash-type method of the actor's business (re-checked
  # under lock). When the business has exactly one active Cash method it is used
  # by default; with several, the user must choose one of them.
  class BulkShortageCashSettler < BulkShortageSettlement
    def initialize(daily_reconciliation_ids:, actor:, notes:, payment_method_id: nil, reference_number: nil)
      super(daily_reconciliation_ids: daily_reconciliation_ids, actor: actor, notes: notes)
      @payment_method_id = payment_method_id.presence&.to_i
      @reference_number  = reference_number.to_s.strip.presence
    end

    # Active Cash-type payment methods of a business — the only methods this
    # destination accepts (also feeds the bulk bar's selector).
    def self.cash_methods_for(business)
      PaymentMethod.for_business(business).active.where(settlement_type: "cash").order(:id)
    end

    private

    def destination_permitted? = @actor.can?(:receive_shortage_settlement_cash)

    def resolve_destination
      methods = self.class.cash_methods_for(@actor.business).to_a
      return :cash_method_missing if methods.empty?

      @payment_method =
        if @payment_method_id
          methods.find { |pm| pm.id == @payment_method_id }
        elsif methods.one?
          methods.first
        end
      return :cash_method_required if @payment_method.nil? && @payment_method_id.nil?

      :cash_method_invalid if @payment_method.nil?
    end

    def lock_destination!
      @payment_method.lock!
      reject!(:cash_method_invalid) unless @payment_method.active? && @payment_method.cash?
    end

    def settle_one!(balance, _dr, bulk_reference)
      amount     = balance.remaining_amount
      ledger_txn = close_balance!(balance, payment_method: @payment_method, reference_number: @reference_number)

      log_audit!(actor: @actor, auditable: balance, action: "settle",
                 metadata: common_audit_metadata(balance, bulk_reference).merge(
                   amount: amount.to_s,
                   settlement_destination: "cash_payment_method",
                   payment_method_id: @payment_method.id,
                   reference_number: @reference_number,
                   ledger_transaction_id: ledger_txn.id
                 ))

      ledger_txn
    end

    def build_result(total:, settled_count:, posted:)
      success(record: @payment_method, total: total, settled_count: settled_count, ledger_transactions: posted)
    end
  end
end
