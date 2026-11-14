module Finance
  # Finance & Sales implementation of the Inventory & Purchasing
  # Inventory::PurchaseRequestAdvanceEffects contract (registered in
  # config/initializers/purchase_request_advance_effects.rb): who may fund an
  # advance from which custody account, who may be a request's responsible
  # employee, and the custody ledger effects of recording (funding) and
  # reversing an advance (S2 — module-boundaries.md §14.2 #6). The legacy supplier-payment
  # reversal keeps the same FinancialSettlementService call and custody credit.
  #
  # It runs inside the caller's transaction (which holds the Purchase Request row
  # lock, and for a reversal the advance's) and opens none of its own; a write it cannot make raises
  # ActiveRecord::RecordInvalid.
  #
  # Funding advances (Inventory::PurchaseRequestAdvanceEffects, 2026-11-13): the
  # money goes to the Purchase Request's responsible employee's custody — never
  # a settlement. Every employee involved (source and responsible) must hold an
  # active custody account and be an active employee with the purchasing
  # permission (PURCHASER_PERMISSION; owners implicitly) — checked by the
  # recorder and again here, after the account locks, before posting (there is
  # no separate confirmation step). The rows, all with the Purchase Request as #source:
  #   - employee custody: the linked pair Finance::CustodyTransactionCreator
  #     #create_transfer records — two "transfer" rows cross-referenced by
  #     transfer_counterparty (source −, responsible +);
  #   - company cash / bank: one "purchase_advance_funding" credit. There is no
  #     company cash/bank ledger, so nothing is debited on the company side
  #     (BUG-049); the method and reference stay on the advance and in the note.
  # Reversal posts the opposite rows; a funding row is undone only that way
  # (CustodyTransaction#advance_funding?).
  module PurchaseRequestAdvanceEffects
    PURCHASER_PERMISSION = :create_purchase_requests

    module_function

    # Was Inventory::PurchaseRequestAdvancesController#load_options (the
    # recorder's account list plus the ledger balances, one grouped query).
    def custody_account_options(actor:)
      contract = Inventory::PurchaseRequestAdvanceEffects
      accounts = purchasers(selectable_custody_accounts(actor))
      balances = balances_of(accounts)
      accounts.map do |account|
        contract::CustodyAccountOption.new(id: account.id, holder_name: holder_name(account),
                                           balance: balances[account.id] || 0)
      end
    end

    # Was PurchaseRequestAdvanceRecorder's account lookup.
    def selectable_custody_account_id(actor:, custody_account_id:)
      purchasers(selectable_custody_accounts(actor).where(id: custody_account_id)).first&.id
    end

    # Business-wide: naming someone responsible needs no custody visibility.
    def responsible_employee_options(actor:)
      contract = Inventory::PurchaseRequestAdvanceEffects
      accounts = purchasers(CustodyAccount.for_business(actor.business).active.includes(:user).ordered)
      balances = balances_of(accounts)
      accounts.map do |account|
        contract::ResponsibleEmployeeOption.new(user_id: account.user_id, name: holder_name(account),
                                                custody_account_id: account.id, balance: balances[account.id] || 0)
      end
    end

    def responsible_custody_account_id(business_id:, user_id:)
      return nil if business_id.blank? || user_id.blank?

      purchasers(CustodyAccount.where(business_id: business_id, user_id: user_id).active).first&.id
    end

    # Before the advance row is inserted (see the contract): the same id-order
    # FOR UPDATE locks advance_funded takes, so a recording never holds a
    # key-share lock on an account another recording is waiting to lock.
    def lock_funding_accounts(business_id:, custody_account_ids:)
      lock_accounts!(*CustodyAccount.where(business_id: business_id, id: custody_account_ids.compact).to_a)
      nil
    end

    # Called as the advance is recorded. Locks the accounts in id order
    # (opposite transfers can never deadlock), after the caller's request lock.
    def advance_funded(advance:, actor:)
      contract  = Inventory::PurchaseRequestAdvanceEffects
      recipient = advance.recipient_custody_account
      source    = advance.custody_account if advance.custody_transfer?
      accounts  = [ source, recipient ].compact
      lock_accounts!(*accounts)
      return contract::Funding.new(status: :custody_account_inactive) unless accounts.all?(&:active?)
      return contract::Funding.new(status: :employee_ineligible) unless accounts.all? { |a| purchaser?(a.user) }

      if source
        debit, credit = post_transfer!(advance, from: source, to: recipient, actor: actor,
                                                notes: funding_transfer_note(advance, source, recipient))
        contract::Funding.new(status: :confirmed, transaction_id: credit.id, counterparty_id: debit.id)
      else
        credit = post_company_funding!(advance, recipient, "purchase_advance_funding", advance.amount, actor,
                                       funding_company_note(advance))
        contract::Funding.new(status: :confirmed, transaction_id: credit.id)
      end
    end

    # The opposite rows. Not refused for an account or employee made inactive
    # since — undoing a movement must always be possible.
    def advance_funding_reversed(advance:, actor:, reason:)
      contract  = Inventory::PurchaseRequestAdvanceEffects
      original  = advance.funding_transaction
      recipient = original.custody_account
      source    = original.transfer_counterparty&.custody_account
      lock_accounts!(*[ source, recipient ].compact)
      notes = funding_reversal_note(advance, reason)

      if source
        debit, credit = post_transfer!(advance, from: recipient, to: source, actor: actor, notes: notes)
        contract::Funding.new(status: :confirmed, transaction_id: debit.id, counterparty_id: credit.id)
      else
        debit = post_company_funding!(advance, recipient, "purchase_advance_funding_reversal", -advance.amount,
                                      actor, notes)
        contract::Funding.new(status: :confirmed, transaction_id: debit.id)
      end
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

    # Purchasing employees only — the same User#can? every policy uses (no
    # second permission rule). The role is read per holder through User#can?:
    # preloading it here would reach into Organization & Access internals
    # (permission_role_boundary_spec.rb), and the lists are one business's
    # custody holders.
    def purchasers(accounts)
      accounts.includes(:user).select { |account| purchaser?(account.user) }
    end

    def purchaser?(user) = user.present? && user.active? && user.can?(PURCHASER_PERMISSION)

    def balances_of(accounts)
      CustodyTransaction.active.where(custody_account_id: accounts.map(&:id)).group(:custody_account_id).sum(:amount)
    end

    def lock_accounts!(*accounts)
      accounts.sort_by(&:id).each(&:lock!)
    end

    # Same shape as Finance::CustodyTransactionCreator#create_transfer. Returns
    # [debit on `from`, credit on `to`].
    def post_transfer!(advance, from:, to:, actor:, notes:)
      attrs = { txn_type: "transfer", source: advance.purchase_request, created_by: actor, notes: notes }
      debit  = from.custody_transactions.create!(business: from.business, amount: -advance.amount, **attrs)
      credit = to.custody_transactions.create!(business: to.business, amount: advance.amount,
                                               transfer_counterparty: debit, **attrs)
      debit.update_column(:transfer_counterparty_id, credit.id)
      from.refresh_balance!
      to.refresh_balance!
      [ debit, credit ]
    end

    def post_company_funding!(advance, account, txn_type, amount, actor, notes)
      account.custody_transactions.create!(business: account.business, txn_type: txn_type, amount: amount,
                                           source: advance.purchase_request, created_by: actor,
                                           notes: notes).tap { account.refresh_balance! }
    end

    def funding_transfer_note(advance, source, recipient)
      I18n.t("finance.custody.purchase_request_advance_funding_transfer_note",
             reference: advance.purchase_request.request_number, advance: advance.id,
             from: holder_name(source), to: holder_name(recipient))
    end

    def funding_company_note(advance)
      I18n.t("finance.custody.purchase_request_advance_funding_company_note",
             method: I18n.t("finance.custody.advance_funding_methods.#{advance.source_kind}"),
             reference: advance.purchase_request.request_number, advance: advance.id,
             payment_reference: advance.reference.presence || "—")
    end

    def funding_reversal_note(advance, reason)
      I18n.t("finance.custody.purchase_request_advance_funding_reversal_note",
             reference: advance.purchase_request.request_number, advance: advance.id, reason: reason)
    end

    def holder_name(account) = account.user&.full_name || account.name

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

    private_class_method :selectable_custody_accounts, :credit_custody!, :purchasers, :purchaser?, :balances_of,
                         :lock_accounts!, :post_transfer!, :post_company_funding!, :funding_transfer_note,
                         :funding_company_note, :funding_reversal_note, :holder_name
  end
end
