class AddFieldsToBranches < ActiveRecord::Migration[8.1]
  def change
    add_column :branches, :phone_number, :string
    add_column :branches, :branch_manager_id, :integer
    add_index  :branches, :branch_manager_id
    add_foreign_key :branches, :users, column: :branch_manager_id
  end
end
