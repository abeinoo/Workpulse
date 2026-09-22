class AddApprovalWorkflowToStockIssues < ActiveRecord::Migration[8.1]
  def up
    add_reference :stock_issues, :submitted_by, null: true, foreign_key: { to_table: :users }
    add_column    :stock_issues, :submitted_at, :datetime

    add_reference :stock_issues, :approved_by, null: true, foreign_key: { to_table: :users }
    add_column    :stock_issues, :approved_at, :datetime

    add_reference :stock_issues, :rejected_by, null: true, foreign_key: { to_table: :users }
    add_column    :stock_issues, :rejected_at, :datetime
    add_column    :stock_issues, :rejection_reason, :text

    add_reference :stock_issues, :issued_by, null: true, foreign_key: { to_table: :users }
    add_column    :stock_issues, :issued_at, :datetime

    add_reference :stock_issues, :cancelled_by, null: true, foreign_key: { to_table: :users }
    add_column    :stock_issues, :cancelled_at, :datetime
    add_column    :stock_issues, :cancellation_reason, :text

    # Historical rows all used the old two-value enum (draft/posted), where
    # "posted" already meant "physically deducted" (see StockIssuePoster) —
    # identical in meaning to the new terminal "issued" state, just renamed.
    # Backfill issued_at/issued_by from created_at/created_by as a best-effort
    # approximation: no separate approval/confirm actor was ever recorded
    # historically, so these legacy rows will show only "Created" + "Issued
    # (legacy)" on the timeline, never a fabricated approval step.
    execute <<~SQL.squish
      UPDATE stock_issues
      SET status = 'issued', issued_at = created_at, issued_by_id = created_by_id
      WHERE status = 'posted'
    SQL

    change_column_default :stock_issues, :status, from: "posted", to: "draft"
  end

  def down
    change_column_default :stock_issues, :status, from: "draft", to: "posted"

    execute <<~SQL.squish
      UPDATE stock_issues
      SET status = 'posted'
      WHERE status = 'issued'
    SQL

    remove_reference :stock_issues, :cancelled_by, foreign_key: { to_table: :users }
    remove_column    :stock_issues, :cancelled_at
    remove_column    :stock_issues, :cancellation_reason

    remove_reference :stock_issues, :issued_by, foreign_key: { to_table: :users }
    remove_column    :stock_issues, :issued_at

    remove_reference :stock_issues, :rejected_by, foreign_key: { to_table: :users }
    remove_column    :stock_issues, :rejected_at
    remove_column    :stock_issues, :rejection_reason

    remove_reference :stock_issues, :approved_by, foreign_key: { to_table: :users }
    remove_column    :stock_issues, :approved_at

    remove_reference :stock_issues, :submitted_by, foreign_key: { to_table: :users }
    remove_column    :stock_issues, :submitted_at
  end
end
