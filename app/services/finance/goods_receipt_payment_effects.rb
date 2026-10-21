module Finance
  # Finance & Sales implementation of the Inventory & Purchasing
  # Inventory::GoodsReceiptPaymentEffects contract (registered in
  # config/initializers/goods_receipt_payment_effects.rb): the settlement ledger
  # and custody ledger effects of a goods receipt's payments (Batch S —
  # module-boundaries.md §14.2 #6, write half).
  #
  # Every operation is the code it replaces in the Inventory services, unchanged:
  # the same FinancialSettlementService calls, CustodyTransaction rows (types,
  # signed amounts, links, finance.custody.* notes), custody-account locks and
  # refresh_balance! calls. It runs inside the caller's transaction (which holds
  # the receipt row lock) and opens none of its own; a write it cannot make raises
  # ActiveRecord::RecordInvalid, as before.
  module GoodsReceiptPaymentEffects
    module_function

    # Was GoodsReceiptApproval#approve!'s custody guard.
    def custody_account_active?(receipt:)
      account = receipt.funding_source
      account.is_a?(CustodyAccount) && account.active?
    end

    # Was GoodsReceiptApproval#post_custody_deduction / #post_accountless_payment.
    def approval_payment(receipt:, amount:, actor:)
      custody_deduction(receipt, receipt.funding_source, amount, actor) if receipt.employee_custody_funded? && amount.positive?
      accountless_payment(receipt, amount, actor) if receipt.accountless_payment_funded?
      nil
    end

    # Was PurchaseRequestAdvanceAllocator#apply!'s settlement row (one per allocation).
    def advance_applied(receipt:, advance:, amount:, actor:, reference:, notes:)
      result = FinancialSettlementService.create(
        settleable:     receipt,
        funding_source: advance,
        source_kind:    FinancialSettlement::ADVANCE_APPLICATION_KIND,
        reference:      reference,
        amount:         amount,
        actor:          actor,
        notes:          notes
      )
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

      nil
    end

    # Was GoodsReceiptSettlementRecorder's source-kind check.
    def payment_source_kind?(source_kind) = FinancialSettlement::PAYMENT_SOURCE_KINDS.include?(source_kind)

    # Was GoodsReceiptSettlementRecorder's account resolution: always the actor's
    # own active custody account, never one named in the request.
    def payer_custody_account_id(actor:) = actor.custody_accounts.active.first&.id

    # Was GoodsReceiptSettlementRecorder#post_settlement! / #debit_custody!, after
    # the account lock (which only serializes writes to its cached balance — a
    # negative balance is valid).
    def record_settlement(receipt:, actor:, source_kind:, custody_account_id:, amount:, reference:, notes:, settled_at:)
      account = custody_account_id && CustodyAccount.find(custody_account_id)
      account&.lock!

      result = FinancialSettlementService.create(
        settleable:     receipt,
        funding_source: account,
        source_kind:    source_kind,
        reference:      reference,
        amount:         amount,
        actor:          actor,
        notes:          notes,
        settled_at:     settled_at
      )
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

      settlement = result.settlement
      if account
        account.custody_transactions.create!(
          business:             account.business,
          txn_type:             "inventory_purchase",
          amount:               -amount,
          source:               receipt,
          financial_settlement: settlement,
          created_by:           actor,
          notes:                I18n.t("finance.custody.inventory_settlement_note",
                                       reference: receipt.receipt_number, settlement: settlement.id)
        )
        account.refresh_balance!
      end

      Inventory::GoodsReceiptPaymentEffects::Payment.new(
        settlement: settlement, settlement_id: settlement.id, reference: settlement.reference,
        custody_account_id: account&.id, employee_id: account&.user_id
      )
    end

    # Was GoodsReceiptSettlementReverser's settlement lookup, refusals,
    # FinancialSettlementService.reverse and #credit_custody!.
    def reverse_settlement(receipt:, settlement_id:, actor:, reason:)
      contract = Inventory::GoodsReceiptPaymentEffects
      original = receipt.financial_settlements.lock.find(settlement_id)
      return contract::Reversal.new(status: :already_reversed) if original.reversal? || original.reversed?
      # Advance applications aren't payments to undo one by one — they are
      # released only by voiding the receipt.
      return contract::Reversal.new(status: :advance_application) if original.advance_application?

      result = FinancialSettlementService.reverse(settlement: original, actor: actor, notes: reason)
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

      reversal = result.settlement
      if original.funding_source.is_a?(CustodyAccount)
        account = original.funding_source
        account.with_lock do
          account.custody_transactions.create!(
            business:             account.business,
            txn_type:             "inventory_purchase_reversal",
            amount:               original.amount,
            source:               receipt,
            financial_settlement: reversal,
            created_by:           actor,
            notes:                I18n.t("finance.custody.inventory_settlement_reversal_note",
                                         reference: receipt.receipt_number, settlement: original.id, reason: reason)
          )
          account.refresh_balance!
        end
      end

      contract::Reversal.new(status: :reversed, settlement: reversal, settlement_id: original.id, reversal_id: reversal.id,
                             amount: original.amount, source_kind: original.source_kind,
                             funding_source_id: original.funding_source_id)
    end

    # Was GoodsReceiptVoider#reverse_settlements! / #reverse_custody_transaction!.
    def reverse_all(receipt:, actor:, notes:)
      results = FinancialSettlementService.reverse_all(settleable: receipt, actor: actor, notes: notes)
      failed = results.find { |r| !r.ok? }
      raise ActiveRecord::RecordInvalid, failed.settlement if failed

      results.each do |result|
        reversal = result.settlement
        next unless reversal.funding_source.is_a?(CustodyAccount)

        account = reversal.funding_source
        account.with_lock do
          account.custody_transactions.create!(
            business:             account.business,
            txn_type:             "inventory_purchase_reversal",
            amount:               -reversal.amount,
            source:               receipt,
            financial_settlement: reversal,
            created_by:           actor,
            notes:                I18n.t("finance.custody.inventory_purchase_reversal_note", reference: receipt.receipt_number)
          )
          account.refresh_balance!
        end
      end
      nil
    end

    # Serializes writes to the account's cached balance (never a limit), then
    # records the settlement and its linked custody debit.
    def custody_deduction(receipt, account, amount, actor)
      account.lock!
      settlement_result = FinancialSettlementService.create(
        settleable:     receipt,
        funding_source: account,
        amount:         amount,
        actor:          actor,
        notes:          I18n.t("finance.custody.inventory_purchase_note", reference: receipt.receipt_number)
      )
      raise ActiveRecord::RecordInvalid, settlement_result.settlement unless settlement_result.ok?

      account.custody_transactions.create!(
        business:             account.business,
        txn_type:             "inventory_purchase",
        amount:               -amount,
        source:               receipt,
        financial_settlement: settlement_result.settlement,
        created_by:           actor,
        notes:                I18n.t("finance.custody.inventory_purchase_note", reference: receipt.receipt_number)
      )
      account.refresh_balance!
    end

    # Company cash / bank: the full amount is paid at approval, no account.
    def accountless_payment(receipt, amount, actor)
      return unless amount.positive?

      result = FinancialSettlementService.create(
        settleable:  receipt,
        source_kind: receipt.funding_source_kind,
        reference:   receipt.receipt_number,
        amount:      amount,
        actor:       actor,
        notes:       I18n.t("finance.custody.inventory_purchase_note", reference: receipt.receipt_number)
      )
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?
    end

    private_class_method :custody_deduction, :accountless_payment
  end
end
