class AddRoleToUsersAndMakeEmployeeOptional < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :role, :integer, null: false, default: 0
    change_column_null :users, :employee_id, true
  end
end
