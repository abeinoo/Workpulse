class AddPermissionLimitsToShifts < ActiveRecord::Migration[8.1]
  def up
    add_column :shifts, :max_late_permission_minutes, :integer
    add_column :shifts, :max_early_leave_permission_minutes, :integer

    # Copy existing business-level limits into every shift that belongs to that business.
    # This preserves the previous behaviour for all live shifts so nothing breaks
    # after the settings UI fields are removed.
    execute <<~SQL
      UPDATE shifts
      SET max_late_permission_minutes        = businesses.max_late_permission_minutes,
          max_early_leave_permission_minutes = businesses.max_early_leave_permission_minutes
      FROM businesses
      WHERE shifts.business_id = businesses.id
    SQL
  end

  def down
    remove_column :shifts, :max_late_permission_minutes
    remove_column :shifts, :max_early_leave_permission_minutes
  end
end
