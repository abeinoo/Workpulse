class CreateProductVariants < ActiveRecord::Migration[7.2]
  def change
    create_table :product_variants do |t|
      t.references :product, null: false, foreign_key: true, index: true
      t.string  :name,     null: false
      t.string  :sku
      t.integer :position, null: false, default: 0
      t.boolean :active,   null: false, default: true
      t.timestamps
    end

    add_index :product_variants, [ :product_id, :position ]
    add_foreign_key :product_barcodes, :product_variants, column: :variant_id
  end
end
