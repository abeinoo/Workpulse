class CreateShifts < ActiveRecord::Migration[8.1]
  def change
    create_table :shifts do |t|
      t.references :business,      null: false, foreign_key: true
      t.string  :name,             null: false
      t.string  :shift_type,       null: false
      t.time    :start_time
      t.time    :end_time
      t.decimal :required_hours,   precision: 4, scale: 2
      t.boolean :active,           null: false, default: true
      t.timestamps
    end

    add_index :shifts, [ :business_id, :name ], unique: true
  end
end
