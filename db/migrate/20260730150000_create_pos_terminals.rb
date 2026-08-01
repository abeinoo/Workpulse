class CreatePosTerminals < ActiveRecord::Migration[8.1]
  def change
    create_table :pos_terminals do |t|
      t.references :business, null: false, foreign_key: true
      t.references :branch,   null: false, foreign_key: true
      t.string  :terminal_id, null: false
      t.string  :label
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :pos_terminals, [ :business_id, :terminal_id ], unique: true
  end
end
