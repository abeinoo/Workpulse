# The per-profile basic salary breakdown Payroll::BasicSalaryCalculator records
# for every calculated payroll entry (date-aware salary: one portion per salary
# profile in force during the period). base_salary stays the single payable
# figure; this records how it was built.
#
# Nullable, no backfill: entries calculated before this column existed keep
# nil (their breakdown was never recorded, and locked entries must not be
# re-derived from today's data).
class AddSalaryBreakdownToPayrollEntries < ActiveRecord::Migration[8.1]
  def change
    add_column :payroll_entries, :salary_breakdown, :jsonb
  end
end
