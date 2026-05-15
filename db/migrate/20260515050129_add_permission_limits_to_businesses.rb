class AddPermissionLimitsToBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :max_late_permission_minutes, :integer
    add_column :businesses, :max_early_leave_permission_minutes, :integer
  end
end
