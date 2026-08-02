class AddInsuranceSnapshotToPayrollEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_entries, :insured, :boolean, null: false, default: false
    add_column :payroll_entries, :employee_insurance_amount, :decimal, precision: 12, scale: 2, null: false, default: 0
    add_column :payroll_entries, :employer_insurance_amount, :decimal, precision: 12, scale: 2, null: false, default: 0
    add_column :payroll_entries, :insurance_number, :string
  end
end
