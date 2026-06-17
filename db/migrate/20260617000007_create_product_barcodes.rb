class CreateProductBarcodes < ActiveRecord::Migration[7.2]
  def up
    create_table :product_barcodes do |t|
      t.references :product,      null: false, foreign_key: true, index: true
      t.string     :barcode,      null: false
      t.string     :barcode_type, null: false, default: "other"
      t.boolean    :is_primary,   null: false, default: false
      # Placeholder column for future product-variant support. No FK until the
      # variants table exists; nullable so all current rows have nil here.
      t.bigint     :variant_id,   null: true

      t.datetime :created_at, null: false
    end

    # Globally unique barcodes — an EAN/UPC code always identifies the same
    # real-world product regardless of which business scanned it.
    add_index :product_barcodes, "lower(barcode)",
              unique: true,
              name:   "index_product_barcodes_on_lower_barcode"

    # Backfill existing product barcodes from the legacy column.
    # Auto-detect barcode type from digit count; mark each as the primary barcode.
    execute <<~SQL
      INSERT INTO product_barcodes
        (product_id, barcode, barcode_type, is_primary, created_at)
      SELECT
        id,
        TRIM(barcode),
        CASE
          WHEN TRIM(barcode) ~ '^[0-9]{13}$' THEN 'ean_13'
          WHEN TRIM(barcode) ~ '^[0-9]{12}$' THEN 'upc_a'
          WHEN TRIM(barcode) ~ '^[0-9]{8}$'  THEN 'ean_8'
          ELSE 'other'
        END,
        true,
        NOW()
      FROM products
      WHERE barcode IS NOT NULL AND TRIM(barcode) <> ''
    SQL
  end

  def down
    drop_table :product_barcodes
  end
end
