class RemoveBarcodeTypeDefault < ActiveRecord::Migration[7.2]
  def up
    change_column_default :product_barcodes, :barcode_type, from: "other", to: nil
    # Existing rows from the backfill already have explicit types; this only
    # affects new records created without an explicit barcode_type, which the
    # model's before_validation hook will fill in via auto-detection.
  end

  def down
    change_column_default :product_barcodes, :barcode_type, from: nil, to: "other"
  end
end
