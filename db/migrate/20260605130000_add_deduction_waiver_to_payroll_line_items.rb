class AddDeductionWaiverToPayrollLineItems < ActiveRecord::Migration[8.1]
  def change
    change_table :payroll_line_items, bulk: true do |t|
      # Payroll-level waiver layer for manual deductions. The underlying
      # PayrollAdjustment ("manual deduction" source of truth) is NEVER modified;
      # the decision to excuse a deduction lives only here, at the payroll layer.
      #
      # deduction_waived = true  => the deduction is excluded from totals (net rises)
      #                             while remaining visible and clearly marked.
      # The reason/by/at trio records WHO waived it, WHY, and WHEN for audit/display.
      t.boolean  :deduction_waived, default: false, null: false
      t.string   :deduction_waiver_reason
      t.integer  :deduction_waived_by_id
      t.datetime :deduction_waived_at
    end

    add_index :payroll_line_items, :deduction_waived_by_id
    add_index :payroll_line_items, [ :payroll_entry_id, :deduction_waived ],
              name: "idx_payroll_line_items_entry_waived"
  end
end
