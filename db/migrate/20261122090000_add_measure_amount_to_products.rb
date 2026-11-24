# The product's Amount, shown with its Measure as the product's size or
# packaging ("355 ml", "1 kg", "500 g"). Optional: nullable, and only a
# positive value is allowed when present. Additive — no existing product row
# is changed, and inventory quantities, movements and settings are untouched.
class AddMeasureAmountToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :measure_amount, :decimal, precision: 12, scale: 3
    add_check_constraint :products, "measure_amount IS NULL OR measure_amount > 0", name: "products_measure_amount_positive"
  end
end
