class RemoveRoleAndIsSuperAdminFromUsers < ActiveRecord::Migration[8.1]
  def up
    remove_index :users, :is_super_admin, if_exists: true
    remove_column :users, :is_super_admin
    remove_column :users, :role
  end

  def down
    add_column :users, :role, :string, default: "employee", null: false
    add_column :users, :is_super_admin, :boolean, default: false, null: false
    add_index :users, :is_super_admin

    Business.find_each do |business|
      business.users.where(id: business.owner_id)
              .update_all(role: "super_admin", is_super_admin: true)
    end
  end
end
