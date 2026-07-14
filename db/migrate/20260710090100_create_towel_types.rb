class CreateTowelTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :towel_types do |t|
      t.references :business, null: false, foreign_key: true
      t.string  :name,   null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :towel_types, [ :business_id, :name ], unique: true
  end
end
