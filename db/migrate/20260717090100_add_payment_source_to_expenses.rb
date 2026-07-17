class AddPaymentSourceToExpenses < ActiveRecord::Migration[8.1]
  def up
    add_column :expenses, :payment_source, :string
    execute "UPDATE expenses SET payment_source = CASE WHEN deduct_from_balance THEN 'employee_custody' ELSE 'unpaid' END"
    change_column_null    :expenses, :payment_source, false
    change_column_default :expenses, :payment_source, "unpaid"
  end

  def down
    remove_column :expenses, :payment_source
  end
end
