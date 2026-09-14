class AddAdditionCancellationToPayrollLineItems < ActiveRecord::Migration[8.1]
  def change
    change_table :payroll_line_items, bulk: true do |t|
      # Payroll-level cancellation layer for additions/bonuses, mirroring the
      # deduction_waived layer above. The underlying PayrollAdjustment (bonus
      # source of truth) is NEVER modified; cancellation lives only here, at
      # the payroll layer, and is terminal (no restore) once applied.
      #
      # addition_cancelled = true => the addition is excluded from totals
      #                              (net falls accordingly) while remaining
      #                              visible and clearly marked "ملغي".
      t.boolean  :addition_cancelled, default: false, null: false
      t.string   :addition_cancellation_reason
      t.integer  :addition_cancelled_by_id
      t.datetime :addition_cancelled_at
    end

    add_index :payroll_line_items, :addition_cancelled_by_id
    add_index :payroll_line_items, [ :payroll_entry_id, :addition_cancelled ],
              name: "idx_payroll_line_items_entry_addition_cancelled"
  end
end
