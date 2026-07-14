class RenameWarehouseOpsBranchTypeToWarehouse < ActiveRecord::Migration[8.1]
  # Data-only migration: renames the "warehouse_ops" branch_type value to
  # "warehouse" to match the values now surfaced in the Admin > Branches UI.
  # Investigated before writing this: as of this migration, zero branches
  # anywhere use "warehouse_ops" (dev/prod data checked) and no application
  # code calls Branch#branch_type_warehouse_ops? — this is a safe rename with
  # no behavior to preserve, but it's still written as a reversible data
  # migration (not a silent constant rename) in case any environment does
  # have such a row.
  def up
    execute "UPDATE branches SET branch_type = 'warehouse' WHERE branch_type = 'warehouse_ops'"
  end

  def down
    execute "UPDATE branches SET branch_type = 'warehouse_ops' WHERE branch_type = 'warehouse'"
  end
end
