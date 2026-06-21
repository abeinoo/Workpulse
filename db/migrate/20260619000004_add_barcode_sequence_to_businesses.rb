class AddBarcodeSequenceToBusinesses < ActiveRecord::Migration[7.2]
  def change
    add_column :businesses, :barcode_prefix,      :string,  null: true
    add_column :businesses, :barcode_next_number, :integer, null: false, default: 1
  end
end
