# products.parent_product_id (the retired Product Family) is ignored by
# Product but still exists until a reviewed migration drops it. Specs that
# prove nothing writes it read it in plain SQL. Remove with the column.
module RetiredProductFamilyColumn
  def raw_parent_product_id(product)
    Product.connection.select_value(Product.sanitize_sql_array([ "SELECT parent_product_id FROM products WHERE id = ?", product.id ]))
  end
end

RSpec.configure { |config| config.include RetiredProductFamilyColumn }
