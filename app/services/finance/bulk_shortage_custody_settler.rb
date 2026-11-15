module Finance
  # Bulk settlement destination 1 (see Finance::BulkShortageSettlement): credits
  # the selected days' open shortages to ONE explicitly selected employee's
  # existing Custody Account — a "Shortage Settlement Deposit". The recipient
  # becomes accountable for that cash in custody; nothing else moves: no
  # TillDeposit, no till session amount, no payment method is created or touched.
  #
  # Per shortage: a positive CustodyTransaction (shortage_settlement_deposit,
  # source = the RemainingDepositBalance) on the recipient's account, then the
  # balance's "settlement" ledger row naming that custody row and NO payment
  # method. Then the account's cached balance is refreshed once and the bulk
  # operation is audited (fail-closed) with every DR / balance / custody id.
  #
  # Mixed original cashiers are allowed (owner decision, Nov 15 2026); the
  # recipient is always the single selected employee.
  #
  # Extra guards: the recipient's account is within ShortageSettlementRecipientScope
  # — the narrow authorization path of THIS operation (settle_remaining_deposit_balance
  # and its branch scope; no manage_employee_balances, owner decision 2026-11-15;
  # CustodyTransactionPolicy is deliberately not consulted, so this grants no
  # general custody access); the account is active and held by an active user. Duplicate
  # credits: row locks + open re-check, and the partial unique index
  # idx_custody_txn_one_active_shortage_settlement.
  #
  # Known limitation: there is no reversal yet — a credit can never be voided on
  # its own, and correcting an erroneous bulk settlement needs a dedicated
  # reversal of both the custody credit and the shortage settlement (BUG-052).
  class BulkShortageCustodySettler < BulkShortageSettlement
    def initialize(daily_reconciliation_ids:, custody_account_id:, actor:, notes:)
      super(daily_reconciliation_ids: daily_reconciliation_ids, actor: actor, notes: notes)
      @custody_account_id = custody_account_id.presence&.to_i
    end

    private

    def destination_permitted? = true # account-level check in #resolve_destination

    def precheck_destination
      :recipient_required if @custody_account_id.nil?
    end

    def resolve_destination
      @account = CustodyAccount.for_business(@actor.business).find_by(id: @custody_account_id)
      return :recipient_invalid if @account.nil?
      # Inactive first so the message is precise (the scope also excludes them);
      # re-checked under the account lock in #lock_destination!.
      return :recipient_inactive unless @account.active? && @account.user&.active?

      :not_authorized unless ShortageSettlementRecipientScope.new(@actor).resolve.exists?(id: @account.id)
    end

    def lock_destination!
      @account.lock!
      reject!(:recipient_inactive) unless @account.active? && @account.user&.active?
    end

    def settle_one!(balance, dr, bulk_reference)
      amount = balance.remaining_amount

      custody_txn = @account.custody_transactions.create!(
        business:   @account.business,
        txn_type:   "shortage_settlement_deposit",
        amount:     amount,
        source:     balance,
        created_by: @actor,
        notes:      custody_note(dr, balance)
      )
      ledger_txn = close_balance!(balance, custody_transaction: custody_txn)

      log_audit!(actor: @actor, auditable: balance, action: "settle",
                 metadata: common_audit_metadata(balance, bulk_reference).merge(
                   amount: amount.to_s,
                   settlement_destination: "custody_account",
                   custody_account_id: @account.id,
                   custody_transaction_id: custody_txn.id,
                   ledger_transaction_id: ledger_txn.id,
                   recipient_user_id: @account.user_id
                 ))

      custody_txn
    end

    def after_settlement!(balances:, total:, dr_ids:, posted:, bulk_reference:)
      @account.refresh_balance!

      log_audit!(actor: @actor, auditable: @account, action: "bulk_shortage_settlement",
                 metadata: { bulk_reference: bulk_reference,
                             total: total.to_s,
                             custody_account_id: @account.id,
                             recipient_user_id: @account.user_id,
                             daily_reconciliation_ids: dr_ids,
                             remaining_deposit_balance_ids: balances.map(&:id),
                             custody_transaction_ids: posted.map(&:id),
                             notes: @notes })
    end

    def build_result(total:, settled_count:, posted:)
      success(record: @account, total: total, settled_count: settled_count, custody_transactions: posted)
    end

    # The custody statement line: which day / branch / original cashier the
    # credited cash came from (the shortage reference — always present), then
    # the operator's notes only when given; no reason is ever made up.
    def custody_note(dr, balance)
      reference = I18n.t("finance.daily_reconciliations.bulk_settle_custody_note",
                         date:    dr.business_date ? I18n.l(dr.business_date) : "—",
                         branch:  dr.branch&.name || "—",
                         cashier: balance.responsible_user&.full_name || "—")
      [ reference, @notes ].compact.join(" ")
    end
  end
end
