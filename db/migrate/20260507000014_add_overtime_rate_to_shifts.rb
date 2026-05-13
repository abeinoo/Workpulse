class AddOvertimeRateToShifts < ActiveRecord::Migration[8.1]
  def change
    add_column :shifts, :overtime_rate_multiplier, :decimal,
               precision: 4, scale: 2, null: false, default: "1.5"
  end
end
