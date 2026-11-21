# Product image gallery: a product has any number of ordered images; the one
# at the lowest position is its primary image (shown wherever the product's
# image is displayed). Each row holds one Active Storage attachment (:file) on
# the application's existing storage service — no second storage system.
#
# Existing single product images (Active Storage attachment Product#image) are
# moved onto the gallery as each product's primary image by RE-POINTING their
# attachment rows (record_type / record_id / name). No file is copied, re-
# uploaded or deleted; blobs and their variants are untouched. `down` moves
# them back (the primary image of each product becomes Product#image again;
# further gallery images are kept as blobs but detached).
class CreateProductImages < ActiveRecord::Migration[8.1]
  def up
    create_table :product_images do |t|
      t.references :business, null: false, foreign_key: true
      t.references :product,  null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.timestamps
    end
    add_index :product_images, [ :product_id, :position ]
    add_check_constraint :product_images, "position > 0", name: "product_images_position_positive"

    moved = select_value("SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'Product' AND name = 'image'").to_i

    execute <<~SQL
      INSERT INTO product_images (business_id, product_id, position, created_at, updated_at)
      SELECT p.business_id, p.id, 1, a.created_at, CURRENT_TIMESTAMP
      FROM active_storage_attachments a
      JOIN products p ON p.id = a.record_id
      WHERE a.record_type = 'Product' AND a.name = 'image'
    SQL

    execute <<~SQL
      UPDATE active_storage_attachments a
      SET record_type = 'ProductImage', record_id = pi.id, name = 'file'
      FROM product_images pi
      WHERE a.record_type = 'Product' AND a.name = 'image' AND pi.product_id = a.record_id
    SQL

    remaining = select_value("SELECT COUNT(*) FROM active_storage_attachments WHERE record_type = 'Product' AND name = 'image'").to_i
    created   = select_value("SELECT COUNT(*) FROM product_images").to_i
    raise "product image move incomplete: #{remaining} left, #{created} of #{moved} moved" unless remaining.zero? && created == moved
  end

  def down
    execute <<~SQL
      UPDATE active_storage_attachments a
      SET record_type = 'Product', record_id = pi.product_id, name = 'image'
      FROM product_images pi
      WHERE a.record_type = 'ProductImage' AND a.name = 'file' AND pi.id = a.record_id
        AND pi.position = (SELECT MIN(position) FROM product_images first WHERE first.product_id = pi.product_id)
    SQL
    execute "DELETE FROM active_storage_attachments WHERE record_type = 'ProductImage'"
    drop_table :product_images
  end
end
