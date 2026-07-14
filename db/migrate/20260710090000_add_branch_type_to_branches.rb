class AddBranchTypeToBranches < ActiveRecord::Migration[8.1]
  def change
    add_column :branches, :branch_type, :string, null: false, default: "sales"
    add_index  :branches, :branch_type
  end
end
