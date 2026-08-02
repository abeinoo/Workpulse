class AddSourcePayrollPeriodToExpenses < ActiveRecord::Migration[8.1]
  def change
    add_reference :expenses, :source_payroll_period, foreign_key: { to_table: :payroll_periods }, index: false

    # At most one ACTIVE system-generated insurance expense per period — mirrors
    # the existing idx_expenses_on_source_pos_import_and_branch convention.
    # Voided rows (never deleted) don't block a fresh one from being generated
    # for the same period.
    add_index :expenses, :source_payroll_period_id,
              unique: true, where: "source_payroll_period_id IS NOT NULL AND voided_at IS NULL",
              name: "idx_expenses_on_active_source_payroll_period"
  end
end
