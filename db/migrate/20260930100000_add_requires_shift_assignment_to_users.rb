# Whether an employee works shift-based schedules and so should be offered for
# ShiftAssignment. Defaults to true so every existing employee keeps today's
# behaviour; HR unticks it for remote staff and roles that don't work shifts.
# The business owner is excluded separately (Shifts::AssignmentEligibility).
class AddRequiresShiftAssignmentToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :requires_shift_assignment, :boolean, null: false, default: true
  end
end
