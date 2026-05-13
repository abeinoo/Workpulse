class AddAreaManagerToBranches < ActiveRecord::Migration[8.1]
  def change
    add_reference :branches, :area_manager, foreign_key: { to_table: :users }, null: true
  end
end
