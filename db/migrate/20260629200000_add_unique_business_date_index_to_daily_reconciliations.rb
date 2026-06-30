class AddUniqueBusinessDateIndexToDailyReconciliations < ActiveRecord::Migration[8.0]
  # Prevents duplicate DailyReconciliation records for the same branch on the
  # same business date once a session is closed (or moves to any terminal state).
  # The existing partial indexes already enforce at-most-one open and at-most-one
  # waiting_for_opening per branch; this index covers all other states.
  #
  # We exclude NULL business_date to protect any legacy records created before
  # the column was populated at open time.
  def change
    add_index :daily_reconciliations,
              %i[branch_id business_date],
              unique: true,
              where:  "business_date IS NOT NULL AND state NOT IN ('open', 'waiting_for_opening')",
              name:   "idx_dr_unique_closed_per_branch_per_date"
  end
end
