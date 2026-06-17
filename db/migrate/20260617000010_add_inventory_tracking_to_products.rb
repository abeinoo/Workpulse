class AddInventoryTrackingToProducts < ActiveRecord::Migration[8.0]
  def up
    add_column :products, :track_inventory,                :boolean, default: true, null: false
    add_column :products, :receive_low_stock_notification,  :boolean, default: true, null: false
    add_column :products, :reorder_level,                  :integer, default: 0,    null: false

    # Back-fill reorder_level from the existing low_stock_level so that existing
    # low-stock alerts continue firing without any manual reconfiguration.
    execute <<~SQL
      UPDATE products
      SET reorder_level = ROUND(low_stock_level)::integer
      WHERE low_stock_level > 0
    SQL
  end

  def down
    remove_column :products, :reorder_level
    remove_column :products, :receive_low_stock_notification
    remove_column :products, :track_inventory
  end
end
