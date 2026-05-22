class AddPermissionRoleToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :permission_role_id, :integer

    add_index :users, :permission_role_id

    add_foreign_key :users, :permission_roles, on_delete: :nullify
  end
end
