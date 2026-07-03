class EnhanceBankStatementTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :bank_statement_transactions, :snapshot_deposit_amount,    :decimal, precision: 12, scale: 2
    add_column :bank_statement_transactions, :snapshot_deposit_date,      :date
    add_column :bank_statement_transactions, :snapshot_deposit_reference, :string
    add_column :bank_statement_transactions, :ignored_reason,             :string
  end
end
