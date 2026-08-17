class AddPerformanceIndexesToDailyReconciliationDomain < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # DR index page's primary query: WHERE business_id = ? ORDER BY opened_at DESC LIMIT 200.
    # Only a single-column business_id index exists today, so Postgres must
    # sort every matching row before applying the LIMIT as the table grows.
    add_index :daily_reconciliations, [ :business_id, :opened_at ],
              name: "index_dr_on_business_id_and_opened_at",
              algorithm: :concurrently

    # POS Import existence checks (build_pos_imported_dr_ids / build_dr_issue_badges)
    # and the show page's PosTransaction.for_calendar_date both filter by
    # business_id + branch_id + a transaction_date range together. Only
    # separate single-column indexes exist today.
    add_index :pos_transactions, [ :business_id, :branch_id, :transaction_date ],
              name: "index_pos_transactions_on_business_branch_date",
              algorithm: :concurrently
  end
end
