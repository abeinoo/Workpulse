class AllowNullOvertimeRateMultiplierOnShifts < ActiveRecord::Migration[8.1]
  # A NULL overtime_rate_multiplier means overtime is disabled for the shift.
  # Drop the NOT NULL constraint and the 1.5 default so the field can be cleared.
  def up
    change_column_null    :shifts, :overtime_rate_multiplier, true
    change_column_default :shifts, :overtime_rate_multiplier, from: 1.5, to: nil
  end

  def down
    change_column_default :shifts, :overtime_rate_multiplier, from: nil, to: 1.5
    change_column_null    :shifts, :overtime_rate_multiplier, false, 1.5
  end
end
