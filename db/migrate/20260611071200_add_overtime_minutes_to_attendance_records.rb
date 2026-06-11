class AddOvertimeMinutesToAttendanceRecords < ActiveRecord::Migration[7.2]
  def change
    add_column :attendance_records, :overtime_minutes, :integer, default: 0, null: false
  end
end
