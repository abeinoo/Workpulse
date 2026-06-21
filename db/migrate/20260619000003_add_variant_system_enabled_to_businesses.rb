class AddVariantSystemEnabledToBusinesses < ActiveRecord::Migration[7.2]
  def change
    add_column :businesses, :variant_system_enabled, :boolean, null: false, default: true
  end
end
