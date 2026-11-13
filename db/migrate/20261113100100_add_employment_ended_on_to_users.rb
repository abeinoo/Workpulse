# R3.2 (roadmap revision 19, OD-9; Q5): the employment end date, a Workforce-
# stewarded column on users. Column only: nothing writes or reads it until R6b,
# and it is not linked to account deactivation. Nullable, no default — existing
# employees are never given an end date by this migration.
#
# Rollback refuses once any end date has been recorded.
class AddEmploymentEndedOnToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :employment_ended_on, :date
  end

  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM users WHERE employment_ended_on IS NOT NULL)")
      raise ActiveRecord::IrreversibleMigration, "users.employment_ended_on holds recorded end dates"
    end

    remove_column :users, :employment_ended_on
  end
end
