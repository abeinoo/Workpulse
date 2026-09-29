# Explicit "warehouse supplies branch" relationship — reporting/configuration
# only. Stock stays owned by the warehouse; nothing here holds or moves stock.
# One row per branch = that branch's primary supplying warehouse (a warehouse
# may supply many branches). No backfill: existing businesses keep the
# ledger-inferred relationship as a fallback until an admin sets one.
class CreateWarehouseBranchSupplies < ActiveRecord::Migration[8.1]
  def change
    create_table :warehouse_branch_supplies do |t|
      t.references :business,  null: false, foreign_key: true
      t.references :warehouse, null: false, foreign_key: true
      t.references :branch,    null: false, foreign_key: true, index: { unique: true }
      t.boolean    :active,    null: false, default: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :updated_by, foreign_key: { to_table: :users }
      t.timestamps
    end
  end
end
