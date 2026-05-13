class AddOvertimeMultiplierToSalaryProfiles < ActiveRecord::Migration[8.0]
  def change
    add_column :salary_profiles, :overtime_multiplier, :decimal,
               precision: 4, scale: 2, default: "1.5", null: false
  end
end
