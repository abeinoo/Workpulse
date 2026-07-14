class CreateTowelAdjustments < ActiveRecord::Migration[8.1]
  def change
    create_table :towel_adjustments do |t|
      t.references :business,   null: false, foreign_key: true
      t.references :towel_type, null: false, foreign_key: true
      t.references :branch,     null: false, foreign_key: true
      t.references :created_by, foreign_key: { to_table: :users }

      t.string  :status,             null: false
      t.decimal :original_quantity,  precision: 12, scale: 3, null: false
      t.decimal :adjustment_quantity, precision: 12, scale: 3, null: false
      t.text    :reason, null: false

      t.timestamps
    end
  end
end
