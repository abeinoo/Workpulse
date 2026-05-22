class DropSystemDefaultFromPermissionRoles < ActiveRecord::Migration[8.1]
  def change
    remove_column :permission_roles, :system_default, :boolean
  end
end
