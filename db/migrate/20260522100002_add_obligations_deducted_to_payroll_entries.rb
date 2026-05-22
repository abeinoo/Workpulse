class AddObligationsDeductedToPayrollEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_entries, :obligations_deducted,
               :decimal, precision: 12, scale: 2, default: "0.0", null: false
  end
end
