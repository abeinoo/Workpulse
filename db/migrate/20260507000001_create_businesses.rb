class CreateBusinesses < ActiveRecord::Migration[8.1]
  def change
    create_table :businesses do |t|
      t.string  :name,     null: false
      t.string  :timezone, null: false, default: "UTC"
      t.text    :settings
      t.boolean :active,   null: false, default: true
      t.timestamps
    end
  end
end
