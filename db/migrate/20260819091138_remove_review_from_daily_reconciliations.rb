class RemoveReviewFromDailyReconciliations < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :daily_reconciliations, column: :reviewed_by_id
    remove_index :daily_reconciliations, name: "index_dr_on_reviewed_by_id"
    remove_column :daily_reconciliations, :reviewed_at, :datetime
    remove_column :daily_reconciliations, :reviewed_by_id, :bigint
  end
end
