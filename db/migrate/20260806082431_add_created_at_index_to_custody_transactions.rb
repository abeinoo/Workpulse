class AddCreatedAtIndexToCustodyTransactions < ActiveRecord::Migration[8.1]
  def change
    # Serves the Finance Dashboard's Cash Flow chart and as-of-date custody
    # balance snapshot, which both filter/group custody_transactions by
    # created_at within a custody_account_id subquery — no index previously
    # existed on this column.
    add_index :custody_transactions, [ :custody_account_id, :created_at ],
              name: "index_custody_transactions_on_account_and_created_at"
  end
end
