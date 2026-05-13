class MakeAttendanceBranchShiftOptional < ActiveRecord::Migration[8.1]
  def change
    change_column_null :attendance_records, :branch_id, true
    change_column_null :attendance_records, :shift_assignment_id, true
    change_column_null :shift_assignments,  :branch_id, true
  end
end
