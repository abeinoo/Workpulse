class CreateObligationDeductions < ActiveRecord::Migration[8.1]
  def change
    create_table :obligation_deductions do |t|
      t.references :employee_obligation, null: false, foreign_key: true
      t.references :payroll_period,      null: false, foreign_key: true

      # Immutable snapshot: values frozen at generation time so historical payroll
      # entries are unaffected if the obligation is edited or closed later.
      t.decimal :deducted_amount,  precision: 12, scale: 2, null: false
      t.decimal :remaining_before, precision: 12, scale: 2, null: false
      t.decimal :remaining_after,  precision: 12, scale: 2, null: false

      t.timestamps
    end

    # One deduction snapshot per obligation per period — prevents duplicate deductions
    # if payroll is regenerated without first destroying existing snapshots.
    add_index :obligation_deductions,
              [ :employee_obligation_id, :payroll_period_id ],
              unique: true,
              name:   "idx_obligation_deductions_unique"
  end
end
