class AddExpensePaymentTypeColumn < ActiveRecord::Migration[8.0]
  def change
    # "direct" vs "installment" is now a genuinely independent axis from
    # deduct_from_balance (whether it's paid from custody) — see Expense
    # model comment. Defaulting every existing row to "direct" is safe: no
    # historical expense ever had installment semantics (the payment-tracking
    # feature is new), so none should retroactively read as an installment
    # plan.
    add_column :expenses, :payment_type, :string, null: false, default: "direct"

    # "Paid from my balance/custody" must be an explicit, opt-in choice —
    # never assumed. Only affects NEW rows going forward (existing rows keep
    # their actual stored value); the interactive form always submits an
    # explicit 0/1 regardless of this default, same as before.
    change_column_default :expenses, :deduct_from_balance, from: true, to: false
  end
end
