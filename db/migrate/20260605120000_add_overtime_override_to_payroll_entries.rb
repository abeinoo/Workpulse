class AddOvertimeOverrideToPayrollEntries < ActiveRecord::Migration[8.1]
  def change
    change_table :payroll_entries, bulk: true do |t|
      # Pristine system-calculated overtime, snapshotted at generation. Attendance
      # stays the source of truth; these are the authoritative "before override" figures.
      t.integer :calculated_overtime_minutes, default: 0, null: false
      t.decimal :calculated_overtime_pay, precision: 12, scale: 2, default: "0.0", null: false

      # The management override. NULL approved_* => no override => calculated values apply.
      # overtime_override_mode records how the manager entered the value:
      #   "minutes" — they approved N minutes (pay derived pro-rata)
      #   "amount"  — they approved a fixed payable amount (minutes derived pro-rata)
      t.integer :approved_overtime_minutes
      t.decimal :approved_overtime_pay, precision: 12, scale: 2
      t.string  :overtime_override_mode

      t.string   :overtime_override_reason
      t.integer  :overtime_overridden_by_id
      t.datetime :overtime_overridden_at

      # Set when a regeneration changed the calculated value underneath an existing
      # override, so a payroll user is prompted to re-review the stale override.
      t.boolean :overtime_override_stale, default: false, null: false
    end

    add_index :payroll_entries, :overtime_overridden_by_id
  end
end
