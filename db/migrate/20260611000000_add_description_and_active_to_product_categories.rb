class AddDescriptionAndActiveToProductCategories < ActiveRecord::Migration[8.1]
  def change
    add_column :product_categories, :description, :text
    add_column :product_categories, :active, :boolean, default: true, null: false
  end
end
