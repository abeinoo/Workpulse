class AddPunchCorrectionDetailsToEmployeeRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_requests, :proposed_time, :time
    add_column :employee_requests, :approved_time, :time
    add_column :employee_requests, :original_check_in_at, :datetime
    add_column :employee_requests, :original_check_out_at, :datetime
  end
end
