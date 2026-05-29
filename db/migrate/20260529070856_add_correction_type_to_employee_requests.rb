class AddCorrectionTypeToEmployeeRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :employee_requests, :correction_type, :string
  end
end
