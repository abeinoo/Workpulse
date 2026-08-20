class AddFullBranchDateUniqueIndexToDailyReconciliations < ActiveRecord::Migration[8.1]
  OLD_INDEX = "idx_dr_unique_closed_per_branch_per_date"
  NEW_INDEX = "idx_dr_unique_branch_business_date"

  # The previous index only covered closed/deposited/verified rows — it
  # explicitly excluded open/waiting_for_opening, so nothing at the DB level
  # ever stopped two DailyReconciliation rows (any state) from sharing the
  # same (branch_id, business_date). This replaces it with one unconditional
  # (per non-null business_date) unique index covering every state, matching
  # the model-level uniqueness validation added alongside this migration.
  def up
    duplicates = select_all(<<~SQL)
      SELECT branch_id, business_date, COUNT(*) AS cnt, array_agg(id ORDER BY id) AS ids
      FROM daily_reconciliations
      WHERE business_date IS NOT NULL
      GROUP BY branch_id, business_date
      HAVING COUNT(*) > 1
    SQL

    if duplicates.rows.any?
      details = duplicates.map { |row| "branch_id=#{row['branch_id']} business_date=#{row['business_date']} ids=#{row['ids']}" }
                          .join("; ")
      raise ActiveRecord::IrreversibleMigration,
            "Cannot add a unique index on (branch_id, business_date): existing duplicate " \
            "DailyReconciliation rows were found — #{details}. Resolve these manually " \
            "(void/merge as appropriate — never delete) before re-running this migration."
    end

    remove_index :daily_reconciliations, name: OLD_INDEX

    add_index :daily_reconciliations, %i[branch_id business_date],
              unique: true,
              where:  "business_date IS NOT NULL",
              name:   NEW_INDEX
  end

  def down
    remove_index :daily_reconciliations, name: NEW_INDEX

    add_index :daily_reconciliations, %i[branch_id business_date],
              unique: true,
              where:  "business_date IS NOT NULL AND state NOT IN ('open', 'waiting_for_opening')",
              name:   OLD_INDEX
  end
end
