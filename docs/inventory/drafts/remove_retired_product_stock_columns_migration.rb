# DRAFT FOR REVIEW — NOT A MIGRATION YET. Nothing loads or runs this file.
#
# It lives outside db/migrate on purpose: a file there would be applied by the
# development server / IDE prompt, by bin/docker-entrypoint (db:prepare) on the
# next container start, and by `kamal deploy` (db:migrate) — i.e. the columns
# would be dropped in Production without a separate approval.
#
# To apply, ONLY after explicit approval and only once the code that ignores
# these columns (Product.ignored_columns, chore/remove-product-level-stock-
# settings) is deployed and running everywhere:
#   1. copy this class to db/migrate/<timestamp>_remove_retired_stock_columns_from_products.rb
#   2. run it in the test database, update db/schema.rb, remove
#      Product.ignored_columns and spec/support/retired_product_stock_columns.rb
#      (and the specs that use it), ship as its own PR and deploy.
# Deploying the drop together with (or before) the ignored_columns change would
# break every running app server: Rails would still INSERT the dropped columns.
#
# Data: the four values are archived per product (append-only copy) before the
# columns go, so no historical value is lost; `down` restores them from it.
class RemoveRetiredStockColumnsFromProducts < ActiveRecord::Migration[8.1]
  ARCHIVE = :retired_product_stock_settings

  def up
    create_table ARCHIVE do |t|
      t.references :product,  null: false, foreign_key: true, index: { unique: true }
      t.references :business, null: false, foreign_key: true
      t.decimal :low_stock_level,  precision: 12, scale: 3, null: false
      t.decimal :reorder_quantity, precision: 12, scale: 3, null: false
      t.integer :reorder_level, null: false
      t.boolean :receive_low_stock_notification, null: false
      t.datetime :archived_at, null: false
    end

    # Every product, defaults included: the archive is the complete record of
    # what the columns held when they were retired.
    execute <<~SQL
      INSERT INTO #{ARCHIVE} (product_id, business_id, low_stock_level, reorder_quantity, reorder_level,
                              receive_low_stock_notification, archived_at)
      SELECT id, business_id, low_stock_level, reorder_quantity, reorder_level,
             receive_low_stock_notification, CURRENT_TIMESTAMP
      FROM products
    SQL

    archived = select_value("SELECT COUNT(*) FROM #{ARCHIVE}").to_i
    products = select_value("SELECT COUNT(*) FROM products").to_i
    raise "archive incomplete: #{archived} of #{products} products" unless archived == products

    remove_column :products, :low_stock_level
    remove_column :products, :reorder_quantity
    remove_column :products, :reorder_level
    remove_column :products, :receive_low_stock_notification
  end

  def down
    add_column :products, :low_stock_level,  :decimal, precision: 12, scale: 3, null: false, default: 0
    add_column :products, :reorder_quantity, :decimal, precision: 12, scale: 3, null: false, default: 0
    add_column :products, :reorder_level, :integer, null: false, default: 0
    add_column :products, :receive_low_stock_notification, :boolean, null: false, default: true

    execute <<~SQL
      UPDATE products p
      SET low_stock_level = a.low_stock_level, reorder_quantity = a.reorder_quantity,
          reorder_level = a.reorder_level, receive_low_stock_notification = a.receive_low_stock_notification
      FROM #{ARCHIVE} a
      WHERE a.product_id = p.id
    SQL

    drop_table ARCHIVE
  end
end
