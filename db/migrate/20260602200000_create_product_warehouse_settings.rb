class CreateProductWarehouseSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :product_warehouse_settings do |t|
      t.references :product,   null: false, foreign_key: true
      t.references :warehouse, null: false, foreign_key: true
      t.decimal :low_stock_level,  precision: 12, scale: 3, null: false, default: 0
      t.decimal :reorder_quantity, precision: 12, scale: 3, null: false, default: 0
      t.timestamps
    end
    add_index :product_warehouse_settings, [ :product_id, :warehouse_id ], unique: true
  end
end
