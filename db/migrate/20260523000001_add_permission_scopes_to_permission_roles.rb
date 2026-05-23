class AddPermissionScopesToPermissionRoles < ActiveRecord::Migration[8.1]
  def change
    add_column :permission_roles, :permission_scopes, :jsonb, default: {}, null: false
  end
end
