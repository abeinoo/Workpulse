module Finance
  # Finance & Sales implementation of the Inventory & Purchasing
  # Inventory::PurchaseRequestAdvanceEffects contract (registered in
  # config/initializers/purchase_request_advance_effects.rb): who may pay an
  # advance from which custody account, and the settlement and custody ledger
  # effects of confirming and reversing a Purchase Request advance (S2 —
  # module-boundaries.md §14.2 #6).
  #
  # Every operation is the code it replaces in the Inventory services, unchanged:
  # the same custody visibility (CustodyAccountPolicy::Scope), the same
  # FinancialSettlementService calls, CustodyTransaction rows (types, signed
  # amounts, links, notes), custody-account locks and refresh_balance! calls. It
  # runs inside the caller's transaction (which holds the Purchase Request and
  # advance row locks) and opens none of its own; a write it cannot make raises
  # ActiveRecord::RecordInvalid, as before.
  module PurchaseRequestAdvanceEffects
    module_function

    # Was Inventory::PurchaseRequestAdvancesController#load_options (the
    # recorder's account list plus the ledger balances, one grouped query).
    def custody_account_options(actor:)
      accounts = selectable_custody_accounts(actor).to_a
      balances = CustodyTransaction.active.where(custody_account_id: accounts.map(&:id))
                                   .group(:custody_account_id).sum(:amount)
      accounts.map do |account|
        Inventory::PurchaseRequestAdvanceEffects::CustodyAccountOption.new(
          id: account.id, holder_name: account.user&.full_name || account.name, balance: balances[account.id] || 0
        )
      end
    end

    # Was PurchaseRequestAdvanceRecorder's account lookup.
    def selectable_custody_account_id(actor:, custody_account_id:)
      selectable_custody_accounts(actor).find_by(id: custody_account_id)&.id
    end

    # Was PurchaseRequestAdvanceWorkflow#confirm!'s account lock and active check,
    # #post_settlement! and #debit_custody!.
    def advance_confirmed(advance:, actor:)
      contract = Inventory::PurchaseRequestAdvanceEffects
      account  = advance.custody_account
      if account
        # Serializes writes to the account's cached balance; never a limit.
        account.lock!
        return contract::Confirmation.new(status: :custody_account_inactive) unless account.active?
      end

      settlement = post_settlement!(advance, actor)
      debit_custody!(account, advance, settlement, actor) if account
      contract::Confirmation.new(status: :confirmed, settlement_id: settlement.id)
    end

    # Was PurchaseRequestAdvanceWorkflow#reverse!'s FinancialSettlementService.reverse
    # and #credit_custody!.
    def advance_reversed(advance:, actor:, reason:)
      original = advance.financial_settlement
      result   = FinancialSettlementService.reverse(settlement: original, actor: actor, notes: reason)
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

      reversal = result.settlement
      credit_custody!(advance, original, reversal, reason, actor) if original.funding_source.is_a?(CustodyAccount)
      Inventory::PurchaseRequestAdvanceEffects::Reversal.new(settlement_id: original.id, reversal_id: reversal.id)
    end

    # Custody accounts an actor may pay an advance from — never a new
    # authorization system: their OWN active account always; anyone else's only
    # with manage_employee_balances, and then only within their existing custody
    # visibility (CustodyAccountPolicy::Scope, branch-scoped).
    # (Was PurchaseRequestAdvanceRecorder.selectable_custody_accounts.)
    def selectable_custody_accounts(actor)
      relation =
        if actor.can?(:manage_employee_balances)
          CustodyAccountPolicy::Scope.new(actor, CustodyAccount).resolve
        else
          CustodyAccount.for_business(actor.business).where(user_id: actor.id)
        end
      relation.active.includes(:user).ordered
    end

    def post_settlement!(advance, actor)
      purchase_request = advance.purchase_request
      result = FinancialSettlementService.create(
        settleable:     purchase_request,
        funding_source: advance.custody_account,
        source_kind:    advance.source_kind,
        reference:      advance.reference.presence || purchase_request.request_number,
        amount:         advance.amount,
        actor:          actor,
        notes:          I18n.t("inventory.purchase_request_advances.settlement_note",
                               reference: purchase_request.request_number, advance: advance.id),
        settled_at:     advance.paid_on
      )
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

      result.settlement
    end

    def debit_custody!(account, advance, settlement, actor)
      purchase_request = advance.purchase_request
      account.custody_transactions.create!(
        business:             account.business,
        txn_type:             "inventory_purchase",
        amount:               -advance.amount,
        source:               purchase_request,
        financial_settlement: settlement,
        created_by:           actor,
        notes:                I18n.t("finance.custody.purchase_request_advance_note",
                                     reference: purchase_request.request_number, advance: advance.id,
                                     supplier: purchase_request.supplier&.name ||
                                               I18n.t("inventory.purchase_requests.no_supplier"))
      )
      account.refresh_balance!
    end

    def credit_custody!(advance, original, reversal, reason, actor)
      purchase_request = advance.purchase_request
      account = original.funding_source
      account.lock!
      account.custody_transactions.create!(
        business:             account.business,
        txn_type:             "inventory_purchase_reversal",
        amount:               original.amount,
        source:               purchase_request,
        financial_settlement: reversal,
        created_by:           actor,
        notes:                I18n.t("finance.custody.purchase_request_advance_reversal_note",
                                     reference: purchase_request.request_number, advance: advance.id, reason: reason)
      )
      account.refresh_balance!
    end

    private_class_method :selectable_custody_accounts, :post_settlement!, :debit_custody!, :credit_custody!
  end
end
