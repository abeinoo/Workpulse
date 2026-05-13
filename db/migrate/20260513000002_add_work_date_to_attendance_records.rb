class AddWorkDateToAttendanceRecords < ActiveRecord::Migration[8.1]
  def up
    add_column :attendance_records, :work_date, :date

    execute "UPDATE attendance_records SET work_date = date"

    change_column_null :attendance_records, :work_date, false

    remove_index :attendance_records, name: "index_attendance_records_on_user_id_and_date"
    add_index :attendance_records, [ :user_id, :work_date ],
              unique: true, name: "index_attendance_records_on_user_id_and_work_date"
  end

  def down
    remove_index :attendance_records, name: "index_attendance_records_on_user_id_and_work_date"
    add_index :attendance_records, [ :user_id, :date ],
              unique: true, name: "index_attendance_records_on_user_id_and_date"
    remove_column :attendance_records, :work_date
  end
end
