class AddDurationMinutesToEmployeeRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_requests, :duration_minutes, :integer
  end
end
