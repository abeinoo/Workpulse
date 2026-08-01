class AddSaleNumberToSalesTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :sales_transactions, :sale_number, :string
    add_index :sales_transactions, :sale_number
  end
end
