class CreateInventoryTables < ActiveRecord::Migration[8.1]
  def change
    create_table :warehouses do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,        null: false
      t.text    :description
      t.string  :status,      null: false, default: "active"
      t.timestamps
    end
    add_index :warehouses, [ :business_id, :name ]

    create_table :suppliers do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,             null: false
      t.string  :primary_mobile
      t.string  :secondary_mobile
      t.decimal :latitude,  precision: 10, scale: 6
      t.decimal :longitude, precision: 10, scale: 6
      t.text    :address
      t.text    :notes
      t.timestamps
    end
    add_index :suppliers, [ :business_id, :name ]

    create_table :brands do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name, null: false
      t.timestamps
    end
    add_index :brands, "business_id, lower(name)", unique: true, name: "index_brands_on_business_id_and_lower_name"

    create_table :product_categories do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name, null: false
      t.timestamps
    end
    add_index :product_categories, "business_id, lower(name)", unique: true,
              name: "index_product_categories_on_business_id_and_lower_name"

    create_table :products do |t|
      t.references :business,           null: false, foreign_key: true
      t.references :brand,              foreign_key: true
      t.references :product_category,   foreign_key: true
      t.string  :name,                  null: false
      t.string  :sku,                   null: false
      t.string  :barcode
      t.decimal :initial_cost_price,        precision: 12, scale: 4, null: false, default: 0
      t.decimal :last_purchase_price,        precision: 12, scale: 4
      t.decimal :average_cost_price,         precision: 12, scale: 4, null: false, default: 0
      t.decimal :low_stock_level,            precision: 12, scale: 3, null: false, default: 0
      t.decimal :reorder_quantity,           precision: 12, scale: 3, null: false, default: 0
      t.decimal :selling_markup_percentage,  precision: 8,  scale: 2, null: false, default: 0
      t.text    :notes
      t.timestamps
    end
    add_index :products, "business_id, lower(sku)", unique: true,
              name: "index_products_on_business_id_and_lower_sku"
    add_index :products, "business_id, lower(barcode)", unique: true,
              where: "barcode IS NOT NULL AND barcode <> ''",
              name: "index_products_on_business_id_and_lower_barcode"

    create_table :goods_receipts do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :warehouse,  null: false, foreign_key: true
      t.references :supplier,   foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string  :receipt_number, null: false
      t.date    :received_on,     null: false
      t.text    :notes
      t.timestamps
    end
    add_index :goods_receipts, [ :business_id, :receipt_number ], unique: true

    create_table :goods_receipt_items do |t|
      t.references :goods_receipt, null: false, foreign_key: true
      t.references :product,       null: false, foreign_key: true
      t.decimal :quantity,   precision: 12, scale: 3, null: false
      t.decimal :unit_cost,  precision: 12, scale: 4, null: false
      t.decimal :total_cost, precision: 14, scale: 4, null: false, default: 0
      t.timestamps
    end

    create_table :stock_issues do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :warehouse,  null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }
      t.string  :issue_number, null: false
      t.date    :issued_on,     null: false
      t.text    :notes
      t.timestamps
    end
    add_index :stock_issues, [ :business_id, :issue_number ], unique: true

    create_table :stock_issue_items do |t|
      t.references :stock_issue, null: false, foreign_key: true
      t.references :product,     null: false, foreign_key: true
      t.decimal :quantity,   precision: 12, scale: 3, null: false
      t.decimal :unit_cost,  precision: 12, scale: 4, null: false, default: 0
      t.decimal :total_cost, precision: 14, scale: 4, null: false, default: 0
      t.timestamps
    end

    create_table :inventory_movements do |t|
      t.references :business,  null: false, foreign_key: true
      t.references :product,   null: false, foreign_key: true
      t.references :warehouse, null: false, foreign_key: true
      t.string  :direction, null: false                  # in / out
      t.string  :reason,    null: false                  # goods_receipt / stock_issue / opening_balance / adjustment / transfer_in / transfer_out
      t.decimal :quantity,  precision: 12, scale: 3, null: false
      t.decimal :unit_cost, precision: 12, scale: 4, null: false, default: 0
      t.references :source, polymorphic: true             # GoodsReceiptItem / StockIssueItem / nil for opening balance
      t.date    :occurred_on, null: false
      t.timestamps
    end
    add_index :inventory_movements, [ :product_id, :warehouse_id ]
    add_index :inventory_movements, [ :business_id, :occurred_on ]
  end
end
