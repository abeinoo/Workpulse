class RemoveMatchColumnsFromBankStatementTransactions < ActiveRecord::Migration[8.1]
  def up
    remove_reference :bank_statement_transactions, :matched_till_deposit, foreign_key: { to_table: :till_deposits }
    remove_column :bank_statement_transactions, :matched_by_id
    remove_column :bank_statement_transactions, :matched_at
    remove_column :bank_statement_transactions, :snapshot_deposit_amount
    remove_column :bank_statement_transactions, :snapshot_deposit_date
    remove_column :bank_statement_transactions, :snapshot_deposit_reference
  end

  def down
    add_reference :bank_statement_transactions, :matched_till_deposit, foreign_key: { to_table: :till_deposits }
    add_column :bank_statement_transactions, :matched_by_id, :bigint
    add_column :bank_statement_transactions, :matched_at, :datetime
    add_column :bank_statement_transactions, :snapshot_deposit_amount, :decimal, precision: 12, scale: 2
    add_column :bank_statement_transactions, :snapshot_deposit_date, :date
    add_column :bank_statement_transactions, :snapshot_deposit_reference, :string
    add_foreign_key :bank_statement_transactions, :users, column: :matched_by_id

    execute <<~SQL
      UPDATE bank_statement_transactions t
      SET matched_till_deposit_id = m.till_deposit_id,
          matched_by_id           = m.matched_by_id,
          matched_at              = m.matched_at,
          snapshot_deposit_amount = d.amount,
          snapshot_deposit_date   = d.deposited_at::date,
          snapshot_deposit_reference = d.reference
      FROM deposit_matches m
      JOIN till_deposits d ON d.id = m.till_deposit_id
      WHERE m.bank_statement_transaction_id = t.id
    SQL

    add_index :bank_statement_transactions, :matched_till_deposit_id, unique: true,
              where: "matched_till_deposit_id IS NOT NULL",
              name: "idx_bank_stmt_txns_on_matched_deposit_unique"
  end
end
