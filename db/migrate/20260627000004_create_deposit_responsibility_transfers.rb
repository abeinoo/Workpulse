class CreateDepositResponsibilityTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :deposit_responsibility_transfers do |t|
      t.references :daily_reconciliation, null: false, foreign_key: true
      t.references :from_user,            null: false, foreign_key: { to_table: :users }
      t.references :to_user,              null: false, foreign_key: { to_table: :users }
      t.datetime   :accepted_at
      t.timestamps
    end

    # At most one pending (un-accepted) transfer per DR at a time.
    # Partial index: accepted transfers don't compete.
    add_index :deposit_responsibility_transfers,
              :daily_reconciliation_id,
              where:  "accepted_at IS NULL",
              unique: true,
              name:   "idx_drt_one_pending_per_dr"
  end
end
