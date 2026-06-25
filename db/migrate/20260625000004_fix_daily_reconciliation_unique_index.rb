class FixDailyReconciliationUniqueIndex < ActiveRecord::Migration[8.1]
  def change
    # The original index only covered (branch_id, business_date).
    # Scoping by business_id is consistent with every other model in the domain
    # and future-proofs against multi-tenant branch ID collisions.
    remove_index :daily_reconciliations,
                 name: "idx_daily_reconciliations_unique_per_branch_day"

    add_index :daily_reconciliations, %i[business_id branch_id business_date],
              unique: true,
              name: "idx_daily_reconciliations_unique_per_branch_day"
  end
end
