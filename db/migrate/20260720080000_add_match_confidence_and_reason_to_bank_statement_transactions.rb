class AddMatchConfidenceAndReasonToBankStatementTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :bank_statement_transactions, :match_confidence, :integer
    add_column :bank_statement_transactions, :match_reason, :text
  end
end
