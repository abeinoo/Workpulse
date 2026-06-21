class AddParentProductIdToProducts < ActiveRecord::Migration[7.2]
  def change
    add_column :products, :parent_product_id, :bigint, null: true
    add_foreign_key :products, :products, column: :parent_product_id, on_delete: :nullify
    add_index :products, :parent_product_id
    add_index :products, [ :business_id, :parent_product_id ],
              name: "index_products_on_business_id_and_parent_product_id"
  end
end
