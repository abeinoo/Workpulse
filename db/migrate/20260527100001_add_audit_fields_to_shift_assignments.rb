class AddAuditFieldsToShiftAssignments < ActiveRecord::Migration[8.1]
  def change
    add_reference :shift_assignments, :created_by,
                  foreign_key: { to_table: :users }, null: true, index: true
    add_reference :shift_assignments, :ended_by,
                  foreign_key: { to_table: :users }, null: true, index: true
  end
end
