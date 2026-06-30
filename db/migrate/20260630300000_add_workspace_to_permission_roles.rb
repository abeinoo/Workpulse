class AddWorkspaceToPermissionRoles < ActiveRecord::Migration[8.0]
  def up
    add_column :permission_roles, :workspace, :string, null: false, default: "management"

    # Backfill: roles explicitly typed as 'employee' get the employee workspace.
    # Every other role_type (branch_manager, area_manager, accountant, nil/custom)
    # stays on the management workspace default.
    execute <<~SQL
      UPDATE permission_roles SET workspace = 'employee' WHERE role_type = 'employee'
    SQL

    add_index :permission_roles, :workspace
  end

  def down
    remove_column :permission_roles, :workspace
  end
end
