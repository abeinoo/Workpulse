# Reviewer-selected date for a punch correction. Together with approved_time it
# is the final punch the reviewer approved; the employee's proposed_date /
# proposed_time are kept untouched alongside it. Nullable: requests approved
# before this column existed have no reviewer-selected date.
class AddApprovedDateToEmployeeRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_requests, :approved_date, :date
  end
end
