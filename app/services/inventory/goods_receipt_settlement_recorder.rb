module Inventory
  # Records one later payment against an approved goods receipt's outstanding
  # amount (typically a Supplier Credit receipt, paid off afterwards in one or
  # more installments). Modeled directly on Finance::ExpensePaymentRecorder and
  # reuses the same generic settlement engine: each payment is one immutable
  # FinancialSettlement row; Paid / Remaining / financial_status are always
  # derived from that ledger (Settleable), never stored on the receipt.
  #
  # Payment sources (FinancialSettlement::SOURCE_KINDS):
  #   - employee_custody — ALWAYS the actor's own active custody account,
  #     resolved server-side exactly like the goods receipt form and
  #     Finance::ExpensePaymentRecorder (`actor.custody_accounts.active.first`).
  #     No account id is ever read from the request, so nobody can pay from
  #     someone else's custody. That account is debited with a real
  #     "inventory_purchase" CustodyTransaction for the FULL amount. The custody
  #     balance is an accounting balance, not a spending limit: it may go
  #     negative (the employee spent more than their recorded custody) — same
  #     rule as Finance::ExpensePaymentRecorder. An actor with no active custody
  #     account (e.g. a super admin) can't use this source.
  #   - company_cash / bank_account — no CashAccount/BankAccount model exists,
  #     so the settlement carries a NIL funding_source plus source_kind and an
  #     optional reference. No internal balance is moved.
  #
  # Settling is a financial event only — it never touches approval_status,
  # status (receiving), stock, or the receipt's amounts.
  class GoodsReceiptSettlementRecorder
    include AuditLoggable

    Result = Struct.new(:ok, :settlement, :receipt, :error, keyword_init: true) { def ok? = ok }

    def initialize(goods_receipt_id, actor:, params:)
      @goods_receipt_id = goods_receipt_id
      @actor            = actor
      @params           = params
    end

    def call
      @receipt = GoodsReceipt.where(business_id: @actor.business_id).find(@goods_receipt_id)

      source_kind = @params[:source_kind].to_s
      return err(t("errors.invalid_source_kind")) unless FinancialSettlement::SOURCE_KINDS.include?(source_kind)

      amount = parse_amount
      return err(t("errors.amount_must_be_positive")) unless amount&.positive?

      payment_date = parse_payment_date
      return err(t("errors.invalid_payment_date")) unless payment_date

      account = nil
      if source_kind == "employee_custody"
        account = @actor.custody_accounts.active.first
        return err(t("errors.no_custody_account")) unless account
      end

      settlement = nil
      ActiveRecord::Base.transaction do
        # Serializes concurrent payments on the same receipt so two requests
        # can't both pass the remaining-amount check and overpay together.
        @receipt.lock!
        return err(t("errors.not_settleable")) if @receipt.voided? || !@receipt.approval_approved?

        remaining = @receipt.remaining_settlement_amount
        return err(t("errors.already_settled")) unless remaining.positive?
        return err(t("errors.exceeds_remaining", remaining: format_amount(remaining))) if amount > remaining

        # No balance check — a negative custody balance is valid. The lock only
        # serializes concurrent writes to the account's cached balance.
        account&.lock!

        settlement = post_settlement!(amount, payment_date, source_kind, account)
        debit_custody!(account, amount, settlement) if account

        log_audit(actor: @actor, auditable: @receipt, action: "record_settlement",
                  metadata: { settlement_id: settlement.id, amount: amount.to_s, source_kind: source_kind,
                              custody_account_id: account&.id, employee_id: account&.user_id,
                              supplier_id: @receipt.supplier_id, reference: settlement.reference })
      end

      Result.new(ok: true, settlement: settlement, receipt: @receipt)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.to_sentence)
    end

    private

    def post_settlement!(amount, payment_date, source_kind, account)
      result = FinancialSettlementService.create(
        settleable:     @receipt,
        funding_source: account,
        source_kind:    source_kind,
        reference:      @params[:reference].to_s.strip.presence,
        amount:         amount,
        actor:          @actor,
        notes:          @params[:notes].to_s.strip.presence,
        settled_at:     payment_date
      )
      raise ActiveRecord::RecordInvalid, result.settlement unless result.ok?

      result.settlement
    end

    def debit_custody!(account, amount, settlement)
      account.custody_transactions.create!(
        business:             account.business,
        txn_type:             "inventory_purchase",
        amount:               -amount,
        source:               @receipt,
        financial_settlement: settlement,
        created_by:           @actor,
        notes:                I18n.t("finance.custody.inventory_settlement_note",
                                     reference: @receipt.receipt_number, settlement: settlement.id)
      )
      account.refresh_balance!
    end

    def parse_amount
      value = BigDecimal(@params[:amount].to_s)
      value.finite? ? value.round(2) : nil
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

    def format_amount(value)
      ActiveSupport::NumberHelper.number_to_rounded(value, precision: 2, delimiter: ",")
    end

    def t(key, **)
      I18n.t("inventory.goods_receipts.settlements.#{key}", **)
    end

    def err(message)
      Result.new(ok: false, receipt: @receipt, error: message)
    end
  end
end
