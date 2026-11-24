# The retired product-level stock columns (products.low_stock_level,
# reorder_quantity, reorder_level, receive_low_stock_notification) are ignored
# by Product, but existing databases still hold old values in them. Specs that
# prove nothing reads those values write and read them in plain SQL.
# Remove this helper together with the columns.
module RetiredProductStockColumns
  COLUMNS = %w[low_stock_level reorder_quantity reorder_level receive_low_stock_notification].freeze

  def write_retired_product_stock_columns!(product, low_stock_level:, reorder_quantity:, reorder_level: 0,
                                           receive_low_stock_notification: true)
    Product.connection.execute(Product.sanitize_sql_array([
      "UPDATE products SET low_stock_level = ?, reorder_quantity = ?, reorder_level = ?, " \
      "receive_low_stock_notification = ? WHERE id = ?",
      low_stock_level, reorder_quantity, reorder_level, receive_low_stock_notification, product.id
    ]))
  end

  # => { "low_stock_level" => BigDecimal, "reorder_quantity" => BigDecimal, "reorder_level" => Integer,
  #      "receive_low_stock_notification" => true/false }
  def retired_product_stock_columns(product)
    row = Product.connection.select_one(Product.sanitize_sql_array(
      [ "SELECT #{COLUMNS.join(', ')} FROM products WHERE id = ?", product.id ]
    ))
    row.to_h { |column, value| [ column, column == "receive_low_stock_notification" ? ActiveModel::Type::Boolean.new.cast(value) : value ] }
       .then { |h| h.merge("low_stock_level" => h["low_stock_level"].to_d, "reorder_quantity" => h["reorder_quantity"].to_d) }
  end
end

RSpec.configure { |config| config.include RetiredProductStockColumns }
