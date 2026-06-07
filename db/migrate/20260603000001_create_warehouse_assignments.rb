class CreateWarehouseAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :warehouse_assignments do |t|
      t.references :user,      null: false, foreign_key: true
      t.references :warehouse, null: false, foreign_key: true
      t.timestamps
    end
    add_index :warehouse_assignments, [ :user_id, :warehouse_id ], unique: true
  end
end
