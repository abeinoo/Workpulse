class CreateDepositMatches < ActiveRecord::Migration[8.1]
  def change
    create_table :deposit_matches do |t|
      t.references :till_deposit, null: false, foreign_key: true
      t.references :bank_statement_transaction, null: false, foreign_key: true

      t.decimal :matched_amount, precision: 12, scale: 2, null: false
      t.references :matched_by, foreign_key: { to_table: :users }
      t.datetime :matched_at, null: false

      t.timestamps
    end

    # A bank transaction's full amount can only ever back one deposit's match
    # until partial allocation is built (see DepositMatch#matched_amount) —
    # removing this index is the only schema change needed to allow a
    # transaction to be split across multiple deposits later.
    add_index :deposit_matches, :bank_statement_transaction_id, unique: true,
              name: "index_deposit_matches_on_transaction_unique"
  end
end
