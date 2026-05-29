class ChangePunchCorrectionTimeColumnsToString < ActiveRecord::Migration[8.1]
  def up
    change_column :employee_requests, :proposed_time, :string
    change_column :employee_requests, :approved_time, :string
  end

  def down
    change_column :employee_requests, :proposed_time, :time
    change_column :employee_requests, :approved_time, :time
  end
end
