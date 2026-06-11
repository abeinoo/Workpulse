class CreateStockTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_transfers do |t|
      t.references :business,    null: false, foreign_key: true
      t.references :source_warehouse,
                   null: false, foreign_key: { to_table: :warehouses }
      t.references :destination_warehouse,
                   null: false, foreign_key: { to_table: :warehouses }
      t.references :created_by, foreign_key: { to_table: :users }
      t.string  :transfer_number, null: false
      t.date    :transferred_on,  null: false
      t.text    :notes
      t.timestamps
    end
    add_index :stock_transfers, [ :business_id, :transfer_number ], unique: true

    create_table :stock_transfer_items do |t|
      t.references :stock_transfer, null: false, foreign_key: true
      t.references :product,        null: false, foreign_key: true
      t.decimal :quantity,   precision: 12, scale: 3, null: false
      t.decimal :unit_cost,  precision: 12, scale: 4, null: false, default: 0
      t.decimal :total_cost, precision: 14, scale: 4, null: false, default: 0
      t.timestamps
    end
  end
end
