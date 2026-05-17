class MakeOvertimeMultiplierOptionalOnSalaryProfiles < ActiveRecord::Migration[8.0]
  def up
    change_column :salary_profiles, :overtime_multiplier, :decimal,
                  precision: 4, scale: 2, null: true, default: nil
  end

  def down
    SalaryProfile.where(overtime_multiplier: nil).update_all(overtime_multiplier: 1.5)
    change_column :salary_profiles, :overtime_multiplier, :decimal,
                  precision: 4, scale: 2, null: false, default: "1.5"
  end
end
