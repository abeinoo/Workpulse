class CreateAttendanceAdjustments < ActiveRecord::Migration[8.1]
  def change
    create_table :attendance_adjustments do |t|
      t.references :attendance_record, null: false, foreign_key: true
      t.references :adjusted_by,       null: false, foreign_key: { to_table: :users }
      t.string :field_name, null: false
      t.text   :old_value
      t.text   :new_value
      t.text   :reason,     null: false
      # No updated_at — adjustments are immutable audit entries
      t.datetime :created_at, null: false
    end

    add_index :attendance_adjustments, [ :attendance_record_id, :created_at ]
  end
end
