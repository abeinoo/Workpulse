class RemoveStaleRemainingDepositBalanceColumns < ActiveRecord::Migration[8.0]
  def up
    remove_foreign_key :remaining_deposit_balances, column: :settled_by_id
    remove_foreign_key :remaining_deposit_balances, column: :settled_by_deposit_id
    remove_column :remaining_deposit_balances, :settled_at
    remove_column :remaining_deposit_balances, :settled_by_id
    remove_column :remaining_deposit_balances, :settled_by_deposit_id
  end

  def down
    add_column :remaining_deposit_balances, :settled_at,             :datetime
    add_column :remaining_deposit_balances, :settled_by_id,          :bigint
    add_column :remaining_deposit_balances, :settled_by_deposit_id,  :bigint
    add_foreign_key :remaining_deposit_balances, :users,        column: :settled_by_id
    add_foreign_key :remaining_deposit_balances, :till_deposits, column: :settled_by_deposit_id
  end
end
