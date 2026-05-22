class AddAlreadyPaidToPayroll < ActiveRecord::Migration[8.1]
  def change
    # Flag on the adjustment record itself
    add_column :payroll_adjustments, :already_paid,   :boolean, default: false, null: false
    add_column :payroll_adjustments, :payment_method, :string   # cash | bank_transfer | check | other
    add_column :payroll_adjustments, :paid_at,        :datetime

    # Propagated to the line item so recalculate_totals! can query it directly
    add_column :payroll_line_items, :already_paid, :boolean, default: false, null: false

    # Stored aggregate on the entry — used in the payslip "Already Paid" deduction row
    add_column :payroll_entries, :already_paid_total,
               :decimal, precision: 12, scale: 2, default: "0.0", null: false
  end
end
