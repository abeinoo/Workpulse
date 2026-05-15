class AddPermissionMinutesToPayrollLineItems < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_line_items, :original_minutes,  :integer
    add_column :payroll_line_items, :permission_minutes, :integer
  end
end
