class AddSoftDeleteToAttendanceRecords < ActiveRecord::Migration[8.0]
  def change
    add_column :attendance_records, :deleted_at,     :datetime
    add_column :attendance_records, :deleted_by_id,  :bigint
    add_column :attendance_records, :deletion_notes, :text

    add_foreign_key :attendance_records, :users, column: :deleted_by_id
    add_index       :attendance_records, :deleted_at
  end
end
