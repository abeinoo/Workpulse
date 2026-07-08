class StockIssueDraftLifecycle < ActiveRecord::Migration[8.0]
  def up
    # Every pre-existing stock issue was created and posted in one atomic step,
    # so the default backfills them all as "posted" — only the new draft-append
    # import flow ever explicitly creates a "draft" one.
    add_column :stock_issues, :status, :string, null: false, default: "posted"
    add_index  :stock_issues, :status

    add_reference :stock_issue_import_rows, :stock_issue_item, foreign_key: true

    # Dropping the column cascades any FK constraint on it in Postgres, so this
    # doesn't depend on whether the constraint actually got created (it didn't,
    # in every environment, for reasons unrelated to this migration).
    remove_column :stock_issue_import_batches, :completion_stock_issue_id, :bigint

    # A batch now always owns the single draft issue it appends to for its
    # entire lifecycle, so the association is no longer optional.
    change_column_null :stock_issue_import_batches, :stock_issue_id, false
  end

  def down
    change_column_null :stock_issue_import_batches, :stock_issue_id, true

    add_column :stock_issue_import_batches, :completion_stock_issue_id, :bigint
    add_foreign_key :stock_issue_import_batches, :stock_issues, column: :completion_stock_issue_id

    remove_reference :stock_issue_import_rows, :stock_issue_item, foreign_key: true

    remove_index  :stock_issues, :status
    remove_column :stock_issues, :status
  end
end
