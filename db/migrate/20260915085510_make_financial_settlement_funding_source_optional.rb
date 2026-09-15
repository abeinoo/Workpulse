class MakeFinancialSettlementFundingSourceOptional < ActiveRecord::Migration[8.0]
  def change
    # A settlement funded from a tracked CustodyAccount is unaffected. A NULL
    # funding source represents money paid through a means this system
    # doesn't model as an account (company cash, bank transfer, a colleague,
    # ...) — the payment itself is still a real, immutable ledger row (Total
    # Paid / Remaining still derive from it), it simply moves no internal
    # balance. See FinancialSettlement and Finance::ExpensePaymentRecorder.
    change_column_null :financial_settlements, :funding_source_id, true
    change_column_null :financial_settlements, :funding_source_type, true
  end
end
