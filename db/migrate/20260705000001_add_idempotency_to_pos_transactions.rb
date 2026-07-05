class AddIdempotencyToPosTransactions < ActiveRecord::Migration[8.0]
  def change
    # Partial unique index: enforced only when reference_number is present.
    # NULL reference_numbers (rows with no ref) are excluded so they can still
    # be inserted freely and don't block each other.
    add_index :pos_transactions, %i[business_id reference_number],
              unique: true,
              where:  "reference_number IS NOT NULL",
              name:   "idx_pos_txn_business_reference_unique"

    add_column :pos_imports, :duplicate_rows, :integer, null: false, default: 0
  end
end
