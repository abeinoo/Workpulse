class CreateServices < ActiveRecord::Migration[8.1]
  def change
    # Minimal salon service catalog. Today this only backs the standalone
    # expected_towel_usage analytical field (Part 4 of the laundry design) — it
    # is NOT wired to PosTransaction, which has no per-service line items yet.
    create_table :services do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name, null: false
      t.decimal :expected_towel_usage, precision: 8, scale: 2, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :services, [ :business_id, :name ], unique: true
  end
end
