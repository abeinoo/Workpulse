# Standard Stock Issue — new workflow: stock is deducted from the warehouse
# of the consuming branch (Inventory::BranchWarehouseResolver); the user no
# longer selects a source warehouse.
#
# warehouse_source records which rule an issue was created under:
#   "selected"          — the source warehouse was chosen by the user (every
#                         issue that exists today, in progress or not). The column
#                         default, so EXISTING ROWS ARE NOT CHANGED: their
#                         warehouse, branch and movements stay exactly as they
#                         are, and they are never re-resolved.
#   "branch_warehouse"  — set by the services for every new Standard Stock
#                         Issue and Quick Issue; the warehouse is re-verified against the
#                         branch at submission, approval and confirmation.
# No backfill.
class AddWarehouseSourceToStockIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :stock_issues, :warehouse_source, :string, null: false, default: "selected"
    add_check_constraint :stock_issues, "warehouse_source IN ('selected', 'branch_warehouse')",
                         name: "stock_issues_warehouse_source_check"
  end
end
