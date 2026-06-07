class CreateStockCounts < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_counts do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :warehouse,  null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :posted_by,  foreign_key: { to_table: :users }
      t.references :stock_adjustment, foreign_key: true
      t.string   :count_number, null: false
      t.date     :counted_on,   null: false
      t.string   :status,       null: false, default: "draft"
      t.text     :notes
      t.datetime :posted_at
      t.timestamps
    end
    add_index :stock_counts, [ :business_id, :count_number ], unique: true

    create_table :stock_count_items do |t|
      t.references :stock_count, null: false, foreign_key: true
      t.references :product,     null: false, foreign_key: true
      t.decimal :system_quantity,  precision: 12, scale: 3, null: false, default: 0
      t.decimal :counted_quantity, precision: 12, scale: 3, null: false, default: 0
      t.decimal :difference,       precision: 12, scale: 3, null: false, default: 0
      t.timestamps
    end
    add_index :stock_count_items, [ :stock_count_id, :product_id ], unique: true
  end
end
