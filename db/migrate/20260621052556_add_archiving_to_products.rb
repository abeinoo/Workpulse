class AddArchivingToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :active, :boolean, null: false, default: true
    add_column :products, :archived_at, :datetime

    add_index :products, [ :business_id, :active ]
  end
end
