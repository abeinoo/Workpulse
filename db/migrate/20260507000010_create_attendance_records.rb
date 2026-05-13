class CreateAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :attendance_records do |t|
      t.references :user,             null: false, foreign_key: true
      t.references :branch,           null: false, foreign_key: true
      t.references :shift_assignment, null: false, foreign_key: true
      t.date    :date,                null: false
      t.datetime :check_in_at,        null: false
      t.datetime :check_out_at
      t.decimal :check_in_latitude,   precision: 10, scale: 8
      t.decimal :check_in_longitude,  precision: 11, scale: 8
      t.decimal :check_out_latitude,  precision: 10, scale: 8
      t.decimal :check_out_longitude, precision: 11, scale: 8
      t.string  :status,              null: false, default: "incomplete"
      t.integer :worked_minutes
      t.integer :late_minutes,        null: false, default: 0
      t.integer :early_leave_minutes, null: false, default: 0
      t.timestamps
    end

    # One record per employee per day
    add_index :attendance_records, [ :user_id, :date ], unique: true
    add_index :attendance_records, [ :branch_id, :date ]
    add_index :attendance_records, [ :user_id, :status ]
  end
end
