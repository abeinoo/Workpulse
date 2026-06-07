class AddDefaultSupplierToProducts < ActiveRecord::Migration[8.1]
  def change
    add_reference :products, :default_supplier,
                  foreign_key: { to_table: :suppliers }, null: true
  end
end
