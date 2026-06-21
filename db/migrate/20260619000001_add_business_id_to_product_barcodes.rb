class AddBusinessIdToProductBarcodes < ActiveRecord::Migration[7.2]
  def up
    # Step 1: add nullable so existing rows can be backfilled without constraint error
    add_column :product_barcodes, :business_id, :bigint, null: true

    # Step 2: backfill from the owning product
    execute <<~SQL
      UPDATE product_barcodes pb
      SET    business_id = p.business_id
      FROM   products p
      WHERE  p.id = pb.product_id
    SQL

    # Step 3: enforce NOT NULL now that all rows have a value
    change_column_null :product_barcodes, :business_id, false

    # Step 4: FK for referential integrity
    add_foreign_key :product_barcodes, :businesses

    # Step 5: swap uniqueness scope — barcodes are unique per business, not globally
    remove_index :product_barcodes, name: "index_product_barcodes_on_lower_barcode"
    add_index :product_barcodes, "business_id, lower(barcode)",
              unique: true,
              name:   "index_product_barcodes_on_business_id_lower_barcode"
  end

  def down
    remove_index  :product_barcodes, name: "index_product_barcodes_on_business_id_lower_barcode"
    remove_foreign_key :product_barcodes, :businesses
    remove_column :product_barcodes, :business_id

    add_index :product_barcodes, "lower(barcode)",
              unique: true,
              name:   "index_product_barcodes_on_lower_barcode"
  end
end
