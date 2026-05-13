class CreateBranches < ActiveRecord::Migration[8.1]
  def change
    create_table :branches do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,                 null: false
      t.string  :address
      t.decimal :latitude,             precision: 10, scale: 8
      t.decimal :longitude,            precision: 11, scale: 8
      t.integer :radius_meters,        default: 100
      t.boolean :geolocation_enabled,  null: false, default: false
      t.boolean :active,               null: false, default: true
      t.timestamps
    end
  end
end
