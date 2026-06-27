class MoveTillSessionAmountsToDailyReconciliation < ActiveRecord::Migration[8.1]
  def up
    # 1. Add the new FK column (nullable first so we can backfill)
    add_reference :till_session_amounts, :daily_reconciliation, null: true, foreign_key: true

    # 2. Backfill from till_sessions → daily_reconciliations
    execute <<~SQL
      UPDATE till_session_amounts tsa
      SET    daily_reconciliation_id = ts.daily_reconciliation_id
      FROM   till_sessions ts
      WHERE  tsa.till_session_id = ts.id
    SQL

    # 3. Enforce NOT NULL now that all rows are filled
    change_column_null :till_session_amounts, :daily_reconciliation_id, false

    # 4. Replace the old unique index with one keyed on daily_reconciliation_id
    remove_index :till_session_amounts, name: "idx_till_session_amounts_unique_method"
    add_index    :till_session_amounts,
                 [:daily_reconciliation_id, :payment_method_id],
                 unique: true,
                 name:   "idx_till_session_amounts_unique_dr_pm"

    # 5. Drop the old till_session_id FK and its index, then the column
    remove_foreign_key :till_session_amounts, column: :till_session_id
    remove_index       :till_session_amounts, name: "index_till_session_amounts_on_till_session_id"
    remove_column      :till_session_amounts, :till_session_id
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
          "Cannot reverse: till_session_id has been dropped and the mapping " \
          "daily_reconciliation_id → till_session_id is 1-to-1 and recoverable " \
          "only from a pre-migration snapshot."
  end
end
