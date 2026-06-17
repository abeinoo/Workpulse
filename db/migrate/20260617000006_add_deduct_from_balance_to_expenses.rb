class AddDeductFromBalanceToExpenses < ActiveRecord::Migration[8.0]
  def change
    add_column :expenses, :deduct_from_balance, :boolean, null: false, default: true
  end
end
