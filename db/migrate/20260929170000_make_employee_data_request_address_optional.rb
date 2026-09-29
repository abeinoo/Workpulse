# The address is optional in the employee data request flow (as it is on the
# employee record); only the request's revisions table had it NOT NULL.
class MakeEmployeeDataRequestAddressOptional < ActiveRecord::Migration[8.1]
  def change
    change_column_null :employee_data_request_revisions, :address, true
  end
end
