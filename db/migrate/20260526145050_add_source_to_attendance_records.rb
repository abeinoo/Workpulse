class AddSourceToAttendanceRecords < ActiveRecord::Migration[8.0]
  def change
    add_column :attendance_records, :check_in_source,  :string
    add_column :attendance_records, :check_out_source, :string

    add_index :attendance_records, :check_in_source
  end
end
