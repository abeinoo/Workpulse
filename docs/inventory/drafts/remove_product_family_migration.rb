# DRAFT FOR REVIEW — NOT A MIGRATION YET. Nothing loads or runs this file.
#
# Removes the database objects used only by the retired Product Family feature
# (parent / child products):
#   products.parent_product_id                         bigint, nullable
#   index_products_on_parent_product_id                 (parent_product_id)
#   index_products_on_business_id_and_parent_product_id (business_id, parent_product_id)
#   foreign key products.parent_product_id -> products.id (ON DELETE SET NULL)
# No table is used only by Product Family.
#
# It lives outside db/migrate on purpose: a file there would be applied by the
# development server / IDE prompt, by bin/docker-entrypoint (db:prepare) on the
# next container start, and by `kamal deploy` (db:migrate) — i.e. the column
# would be dropped in Production without a separate approval.
#
# To apply, ONLY after explicit approval and only once the code that ignores the
# column (Product.ignored_columns, chore/remove-product-level-stock-settings) is
# deployed and running everywhere: copy the class to
# db/migrate/<timestamp>_remove_product_family_from_products.rb, run it in the
# test database, update db/schema.rb, remove "parent_product_id" from
# Product.ignored_columns, ship as its own PR and deploy. Deploying the drop
# with (or before) the ignored_columns change would break running app servers.
#
# Data: no product, stock, movement or document row is changed or deleted.
# Every existing parent link is copied first (append-only archive), so which
# products formed a family stays on record; `down` restores the links.
class RemoveProductFamilyFromProducts < ActiveRecord::Migration[8.1]
  ARCHIVE = :retired_product_family_links

  def up
    create_table ARCHIVE do |t|
      t.references :product,        null: false, foreign_key: { to_table: :products }, index: { unique: true }
      t.references :parent_product, null: false, foreign_key: { to_table: :products }
      t.references :business,       null: false, foreign_key: true
      t.datetime :archived_at, null: false
    end

    execute <<~SQL
      INSERT INTO #{ARCHIVE} (product_id, parent_product_id, business_id, archived_at)
      SELECT id, parent_product_id, business_id, CURRENT_TIMESTAMP
      FROM products
      WHERE parent_product_id IS NOT NULL
    SQL

    linked   = select_value("SELECT COUNT(*) FROM products WHERE parent_product_id IS NOT NULL").to_i
    archived = select_value("SELECT COUNT(*) FROM #{ARCHIVE}").to_i
    raise "archive incomplete: #{archived} of #{linked} parent links" unless archived == linked

    remove_foreign_key :products, column: :parent_product_id
    remove_index :products, name: "index_products_on_business_id_and_parent_product_id"
    remove_index :products, name: "index_products_on_parent_product_id"
    remove_column :products, :parent_product_id
  end

  def down
    add_column :products, :parent_product_id, :bigint
    add_index :products, :parent_product_id, name: "index_products_on_parent_product_id"
    add_index :products, [ :business_id, :parent_product_id ], name: "index_products_on_business_id_and_parent_product_id"
    add_foreign_key :products, :products, column: :parent_product_id, on_delete: :nullify

    execute <<~SQL
      UPDATE products p SET parent_product_id = a.parent_product_id
      FROM #{ARCHIVE} a WHERE a.product_id = p.id
    SQL

    drop_table ARCHIVE
  end
end
