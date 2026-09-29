# Gives a model a financial settlement lifecycle (pending_settlement →
# partially_settled → settled) derived entirely from its FinancialSettlement
# ledger — never stored, exactly like DailyReconciliation's state or
# TillHandover's current_holder. Settlement status is independent of whatever
# other lifecycle the model has (e.g. GoodsReceipt's draft/confirmed/voided).
#
# Including models must implement #settlement_total: the amount considered
# "fully settled" (e.g. GoodsReceipt#total_value).
#
# Settlements are only ever created or reversed through FinancialSettlementService
# — never built directly against #financial_settlements.
module Settleable
  extend ActiveSupport::Concern

  FINANCIAL_STATUSES = %w[pending_settlement partially_settled settled].freeze

  included do
    has_many :financial_settlements, as: :settleable, dependent: :restrict_with_error
  end

  def total_settled_amount
    financial_settlements.sum(:amount)
  end

  def remaining_settlement_amount
    [ settlement_total - total_settled_amount, 0 ].max
  end

  def financial_status
    settled = total_settled_amount
    return "pending_settlement" if settled <= 0
    return "settled" if settled >= settlement_total

    "partially_settled"
  end

  class_methods do
    # { record_id => settled amount } for many records in one query — the same
    # SUM over the FinancialSettlement ledger as #total_settled_amount, for
    # report pages that list many settleables at once.
    def settled_amounts_for(ids)
      FinancialSettlement.where(settleable_type: name, settleable_id: ids)
                         .group(:settleable_id).sum(:amount)
    end
  end

  def pending_settlement? = financial_status == "pending_settlement"
  def partially_settled?  = financial_status == "partially_settled"
  def settled?             = financial_status == "settled"

  def settlement_total
    raise NotImplementedError, "#{self.class} must implement #settlement_total"
  end
end
