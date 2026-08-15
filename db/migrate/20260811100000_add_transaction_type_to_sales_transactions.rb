class AddTransactionTypeToSalesTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :sales_transactions, :transaction_type, :string, default: "sale", null: false
  end
end
