class AddUnitOfMeasureToProducts < ActiveRecord::Migration[8.1]
  def change
    # Display-only. No conversion math is introduced: a product's quantities
    # (goods receipts, issues, transfers, laundry consumption) are always in
    # this one unit — never mixed (e.g. detergent always in kg, never kg/g on
    # the same product).
    add_column :products, :unit_of_measure, :string, null: false, default: "pieces"
  end
end
