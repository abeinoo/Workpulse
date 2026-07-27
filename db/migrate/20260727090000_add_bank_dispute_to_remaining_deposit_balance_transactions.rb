class AddBankDisputeToRemainingDepositBalanceTransactions < ActiveRecord::Migration[8.0]
  def change
    add_reference :remaining_deposit_balance_transactions, :bank_dispute,
                   foreign_key: true, index: true, null: true
  end
end
