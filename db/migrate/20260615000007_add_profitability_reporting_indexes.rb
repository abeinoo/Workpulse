class AddProfitabilityReportingIndexes < ActiveRecord::Migration[8.1]
  # Branch profitability and the expense/consumption reports filter by branch_id
  # together with a date range. Composite [branch_id, <date>] indexes serve those
  # hot paths; their leading branch_id column also covers plain branch_id lookups
  # and FK joins, so the single-column branch_id indexes added with the columns
  # become redundant write overhead — dropped here. (inventory_movements is an
  # append-heavy ledger, so avoiding a duplicate index matters.)
  def change
    add_index :expenses, [ :branch_id, :expense_date ]
    remove_index :expenses, column: :branch_id, name: "index_expenses_on_branch_id"

    add_index :inventory_movements, [ :branch_id, :occurred_on ]
    remove_index :inventory_movements, column: :branch_id,
                 name: "index_inventory_movements_on_branch_id"
  end
end
