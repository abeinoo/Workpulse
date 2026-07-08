class AddReviewToDailyReconciliations < ActiveRecord::Migration[8.1]
  def change
    add_column :daily_reconciliations, :reviewed_at, :datetime

    add_reference :daily_reconciliations, :reviewed_by,
                  null:        true,
                  foreign_key: { to_table: :users },
                  index:       { name: "index_dr_on_reviewed_by_id" }
  end
end
