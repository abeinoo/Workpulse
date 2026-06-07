class CreateStockAdjustments < ActiveRecord::Migration[8.1]
  def change
    create_table :stock_adjustments do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :warehouse,  null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.references :voided_by,  foreign_key: { to_table: :users }
      t.string   :adjustment_number, null: false
      t.date     :adjusted_on,       null: false
      t.string   :reason,            null: false
      t.text     :notes
      t.datetime :voided_at
      t.text     :void_reason
      t.timestamps
    end
    add_index :stock_adjustments, [ :business_id, :adjustment_number ], unique: true

    create_table :stock_adjustment_items do |t|
      t.references :stock_adjustment, null: false, foreign_key: true
      t.references :product,          null: false, foreign_key: true
      t.decimal :quantity_difference, precision: 12, scale: 3, null: false
      t.decimal :unit_cost,           precision: 12, scale: 4, null: false, default: 0
      t.decimal :total_cost,          precision: 14, scale: 4, null: false, default: 0
      t.timestamps
    end
  end
end
