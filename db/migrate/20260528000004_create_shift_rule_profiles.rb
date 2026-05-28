class CreateShiftRuleProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :shift_rule_profiles do |t|
      t.references :business, null: false, foreign_key: true

      t.string  :name,        null: false
      t.text    :description

      # Work-hour overrides
      t.decimal :expected_work_hours, precision: 5, scale: 2  # e.g. 6.0 for Ramadan
      t.integer :break_minutes                                  # deducted before overtime calc

      # Grace windows (raw minutes reduced by this before recording)
      t.integer :late_grace_minutes
      t.integer :early_leave_grace_minutes

      # Overtime policy
      t.boolean :overtime_enabled,    default: true, null: false
      t.decimal :overtime_multiplier, precision: 5, scale: 2

      t.boolean :active, default: true, null: false

      t.timestamps
    end

    add_index :shift_rule_profiles, [ :business_id, :name ], unique: true
  end
end
