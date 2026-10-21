module Inventory
  # Records one later payment against an approved goods receipt's outstanding
  # amount (typically a Supplier Credit receipt, paid off afterwards in one or
  # more installments). Modeled directly on Finance::ExpensePaymentRecorder and
  # reuses the same generic settlement engine: each payment is one immutable
  # FinancialSettlement row; Paid / Remaining / financial_status are always
  # derived from that ledger (Settleable), never stored on the receipt.
  #
  # Payment sources (FinancialSettlement::PAYMENT_SOURCE_KINDS):
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
  # The settlement and custody rows (and the account resolution and lock) are
  # Finance & Sales', through Inventory::GoodsReceiptPaymentEffects (Batch S).
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
      return err(t("errors.invalid_source_kind")) unless Inventory::GoodsReceiptPaymentEffects.payment_source_kind?(source_kind)

      amount = parse_amount
      return err(t("errors.amount_must_be_positive")) unless amount&.positive?

      payment_date = parse_payment_date
      return err(t("errors.invalid_payment_date")) unless payment_date

      # Resolved by Finance & Sales: always the actor's own active custody account.
      custody_account_id = nil
      if source_kind == "employee_custody"
        custody_account_id = Inventory::GoodsReceiptPaymentEffects.payer_custody_account_id(actor: @actor)
        return err(t("errors.no_custody_account")) unless custody_account_id
      end

      payment = nil
      ActiveRecord::Base.transaction do
        # Serializes concurrent payments on the same receipt so two requests
        # can't both pass the remaining-amount check and overpay together.
        @receipt.lock!
        return err(t("errors.not_settleable")) if @receipt.voided? || !@receipt.approval_approved?

        remaining = @receipt.remaining_settlement_amount
        return err(t("errors.already_settled")) unless remaining.positive?
        return err(t("errors.exceeds_remaining", remaining: format_amount(remaining))) if amount > remaining

        # Finance & Sales locks the custody account (after the receipt), records
        # the settlement and debits the account. No balance check — a negative
        # custody balance is valid.
        payment = Inventory::GoodsReceiptPaymentEffects.record_settlement(
          receipt: @receipt, actor: @actor, source_kind: source_kind, custody_account_id: custody_account_id,
          amount: amount, reference: @params[:reference].to_s.strip.presence,
          notes: @params[:notes].to_s.strip.presence, settled_at: payment_date
        )

        log_audit(actor: @actor, auditable: @receipt, action: "record_settlement",
                  metadata: { settlement_id: payment.settlement_id, amount: amount.to_s, source_kind: source_kind,
                              custody_account_id: payment.custody_account_id, employee_id: payment.employee_id,
                              supplier_id: @receipt.supplier_id, reference: payment.reference })
      end

      Result.new(ok: true, settlement: payment.settlement, receipt: @receipt)
    rescue ActiveRecord::RecordInvalid => e
      err(e.record.errors.full_messages.to_sentence)
    end

    private

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
