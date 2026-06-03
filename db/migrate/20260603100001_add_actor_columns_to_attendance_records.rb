class AddActorColumnsToAttendanceRecords < ActiveRecord::Migration[7.2]
  def change
    # Audit trail for manually-created / manually-edited attendance records.
    # Nullable: records created via mobile / biometric / import have no actor.
    add_column :attendance_records, :created_by_id, :integer
    add_column :attendance_records, :updated_by_id, :integer
    add_index  :attendance_records, :created_by_id
    add_index  :attendance_records, :updated_by_id
  end
end
