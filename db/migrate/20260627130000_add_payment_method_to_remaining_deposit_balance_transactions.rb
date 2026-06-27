class AddPaymentMethodToRemainingDepositBalanceTransactions < ActiveRecord::Migration[8.0]
  def change
    add_reference :remaining_deposit_balance_transactions, :payment_method,
                  null: true, foreign_key: true
    add_column    :remaining_deposit_balance_transactions, :reference_number, :string
  end
end
