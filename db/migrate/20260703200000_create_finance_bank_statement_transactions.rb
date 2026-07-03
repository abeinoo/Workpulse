class CreateFinanceBankStatementTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :bank_statement_transactions do |t|
      t.references :bank_statement, null: false, foreign_key: true
      t.references :business,       null: false, foreign_key: true

      t.date    :transaction_date,       null: false
      t.decimal :amount,                 null: false, precision: 12, scale: 2
      t.string  :reference_number
      t.string  :description
      t.string  :external_transaction_id
      t.jsonb   :raw_data,               null: false, default: {}

      t.string  :status,                 null: false, default: "pending"

      t.bigint  :matched_till_deposit_id
      t.string  :match_method
      t.bigint  :matched_by_id
      t.datetime :matched_at
      t.text    :match_notes

      t.timestamps null: false
    end

    add_index :bank_statement_transactions, [:business_id, :status]
    add_index :bank_statement_transactions, :transaction_date
    add_index :bank_statement_transactions,
              :matched_till_deposit_id,
              unique: true,
              where: "matched_till_deposit_id IS NOT NULL",
              name: "idx_bank_stmt_txns_on_matched_deposit_unique"

    add_foreign_key :bank_statement_transactions, :till_deposits,
                    column: :matched_till_deposit_id
    add_foreign_key :bank_statement_transactions, :users,
                    column: :matched_by_id
  end
end
