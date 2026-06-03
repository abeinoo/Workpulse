class AddProposedDateToEmployeeRequests < ActiveRecord::Migration[7.2]
  def change
    # Actual calendar date of the punch being corrected. Distinct from
    # requested_for_date (the business/work date) so overnight shifts whose
    # punches cross midnight are unambiguous.
    add_column :employee_requests, :proposed_date, :date
  end
end
