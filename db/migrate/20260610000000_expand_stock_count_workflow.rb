class ExpandStockCountWorkflow < ActiveRecord::Migration[8.1]
  def up
    # "posted" was the single terminal state; it becomes "approved" in the new
    # draft → in_progress → completed → approved workflow.
    rename_column :stock_counts, :posted_at,    :approved_at
    rename_column :stock_counts, :posted_by_id, :approved_by_id

    add_column :stock_counts, :started_at,      :datetime
    add_column :stock_counts, :completed_at,    :datetime
    add_reference :stock_counts, :completed_by,
                  foreign_key: { to_table: :users }, null: true

    execute "UPDATE stock_counts SET status = 'approved' WHERE status = 'posted'"
  end

  def down
    execute "UPDATE stock_counts SET status = 'posted' WHERE status = 'approved'"

    remove_reference :stock_counts, :completed_by, foreign_key: { to_table: :users }
    remove_column :stock_counts, :completed_at
    remove_column :stock_counts, :started_at

    rename_column :stock_counts, :approved_by_id, :posted_by_id
    rename_column :stock_counts, :approved_at,    :posted_at
  end
end
