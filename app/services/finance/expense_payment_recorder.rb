module Finance
  # Records one manual installment payment against an approved expense's
  # agreed amount — the entry point for the partial-payment / payment-tracking
  # feature. Reuses the existing generic settlement engine rather than a
  # parallel model: each payment is a FinancialSettlement row (immutable,
  # append-only — see FinancialSettlement). Total Paid / Remaining are always
  # derived from the ledger (Settleable#total_settled_amount /
  # #remaining_settlement_amount) — never stored redundantly.
  #
  # "Paid from my balance" is OPTIONAL and independently chosen for EACH
  # payment by whoever is recording it (@actor) — never assumed from the
  # expense's creator, its payment_type, or any prior payment on the same
  # expense. Checked: uses @actor's own custody account, mirroring the
  # existing single full-amount deduction Finance::ExpenseApproval posts on
  # approval for employee_custody-funded expenses (same "expense_deduction"
  # CustodyTransaction, same negative-balance-is-allowed rule — only the
  # expense's own remaining agreed amount is a hard cap; overpayment is not
  # permitted). Unchecked: the FinancialSettlement is posted with a NIL
  # funding_source — the payment is still real and still counts toward Total
  # Paid, it simply moves no internal balance (money paid through company
  # cash, a bank transfer, or someone else entirely — sources this system
  # doesn't model as a trackable account).
  class ExpensePaymentRecorder
    include AuditLoggable

    Result = Struct.new(:ok, :settlement, :expense, :error, keyword_init: true) { def ok? = ok }

    def initialize(expense_id, actor:, params:)
      @expense_id = expense_id
      @actor      = actor
      @params     = params
    end

    def call
      expense = Expense.where(business_id: @actor.business_id).find(@expense_id)

      unless expense.approved?
        return err(expense, I18n.t("finance.expenses.errors.payment_requires_approved"))
      end

      amount = parse_amount
      return err(expense, I18n.t("finance.expenses.errors.amount_must_be_positive")) unless amount&.positive?

      remaining = expense.remaining_settlement_amount
      if amount > remaining
        return err(expense, I18n.t("finance.expenses.errors.payment_exceeds_remaining",
                                    remaining: remaining.round(2)))
      end

      account = nil
      if paid_from_balance?
        account = @actor.custody_accounts.active.first
        return err(expense, I18n.t("finance.expenses.errors.no_balance_account_for_actor")) unless account
      end

      payment_date = parse_payment_date
      return err(expense, I18n.t("finance.expenses.errors.invalid_payment_date")) unless payment_date

      settlement = nil
      ActiveRecord::Base.transaction do
        if account
          account.with_lock do
            settlement = post_settlement!(expense, amount, payment_date, account)

            account.custody_transactions.create!(
              business:   account.business,
              txn_type:   "expense_deduction",
              amount:     -amount,
              expense:    expense,
              created_by: @actor,
              notes:      @params[:notes].presence ||
                          I18n.t("finance.custody.expense_deduction_note", reference: expense.reference_number)
            )
            account.refresh_balance!
          end
        else
          settlement = post_settlement!(expense, amount, payment_date, nil)
        end

        log_audit(actor: @actor, auditable: expense, action: "record_payment",
                  metadata: { custody_account_id: account&.id, amount: amount, settlement_id: settlement.id })
      end

      Result.new(ok: true, settlement: settlement, expense: expense)
    rescue ActiveRecord::RecordInvalid => e
      Result.new(ok: false, expense: expense, error: e.record.errors.full_messages.to_sentence)
    end

    private

    def post_settlement!(expense, amount, payment_date, account)
      settlement_result = FinancialSettlementService.create(
        settleable:     expense,
        funding_source: account,
        amount:         amount,
        actor:          @actor,
        notes:          @params[:notes].presence,
        settled_at:     payment_date
      )
      raise ActiveRecord::RecordInvalid, settlement_result.settlement unless settlement_result.ok?

      settlement_result.settlement
    end

    def paid_from_balance?
      ActiveModel::Type::Boolean.new.cast(@params[:paid_from_balance])
    end

    def parse_amount
      value = BigDecimal(@params[:amount].to_s)
      value.finite? ? value : nil
    rescue ArgumentError, TypeError
      nil
    end

    def parse_payment_date
      value = @params[:payment_date]
      return Time.current if value.blank?

      value.is_a?(Date) || value.is_a?(Time) ? value : Date.parse(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def err(expense, message)
      Result.new(ok: false, expense: expense, error: message)
    end
  end
end
