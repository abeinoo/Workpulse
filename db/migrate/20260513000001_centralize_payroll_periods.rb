class CentralizePayrollPeriods < ActiveRecord::Migration[8.1]
  def up
    # Null out branch_id on all periods so the new unique index
    # (business_id, period_year, period_month) doesn't conflict.
    execute "UPDATE payroll_periods SET branch_id = NULL"

    remove_index :payroll_periods, name: "index_payroll_periods_unique"
    add_index :payroll_periods, [:business_id, :period_year, :period_month],
              unique: true, name: "index_payroll_periods_unique"
  end

  def down
    remove_index :payroll_periods, name: "index_payroll_periods_unique"
    add_index :payroll_periods, [:business_id, :branch_id, :period_year, :period_month],
              unique: true, name: "index_payroll_periods_unique"
  end
end
