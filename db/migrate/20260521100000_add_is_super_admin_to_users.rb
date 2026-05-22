class AddIsSuperAdminToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :is_super_admin, :boolean, default: false, null: false
    User.where(role: "super_admin").update_all(is_super_admin: true)
    add_index :users, :is_super_admin
  end

  def down
    remove_index :users, :is_super_admin
    remove_column :users, :is_super_admin
  end
end
