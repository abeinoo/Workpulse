class CreateLaundryBatchConsumptions < ActiveRecord::Migration[8.1]
  def change
    create_table :laundry_batch_consumptions do |t|
      t.references :laundry_batch,      null: false, foreign_key: true
      t.references :product,            null: false, foreign_key: true
      t.references :inventory_movement, null: false, foreign_key: true

      t.decimal :quantity,            precision: 12, scale: 3, null: false
      t.decimal :unit_cost_snapshot,  precision: 12, scale: 4, null: false, default: 0
      t.decimal :total_cost_snapshot, precision: 14, scale: 4, null: false, default: 0

      t.timestamps
    end
  end
end
