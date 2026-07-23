class AddTransactionTypeToBankStatementTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :bank_statement_transactions, :transaction_type, :string
  end
end
