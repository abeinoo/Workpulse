# Business-level ("unallocated") payroll expenses: the employer insurance cost
# of floating employees (no home branch) is recorded as its own expense with no
# branch and no branch split, never attributed to an arbitrary branch.
#
# - expenses.unallocated marks that expense explicitly, so it is never confused
#   with an ordinary expense missing its branch; the check constraint allows it
#   only on a payroll-generated expense with no branch and no shared split.
# - A finalized period may now have one active branch-attributed insurance
#   expense AND one active unallocated one: the partial unique index moves from
#   (source_payroll_period_id) to (source_payroll_period_id, unallocated).
#
# Rollback: restoring the single-column unique index fails while a period has
# both active expenses, and dropping the column loses which expense was
# unallocated. Roll back the code only and keep this migration; if a rollback
# is unavoidable, void (reopen) those periods' expenses first.
class AddUnallocatedToExpenses < ActiveRecord::Migration[8.1]
  def change
    add_column :expenses, :unallocated, :boolean, default: false, null: false

    add_check_constraint :expenses,
                         "NOT unallocated OR (branch_id IS NULL AND is_shared = false AND source_payroll_period_id IS NOT NULL)",
                         name: "expenses_unallocated_payroll_only"

    remove_index :expenses, :source_payroll_period_id,
                 unique: true, where: "((source_payroll_period_id IS NOT NULL) AND (voided_at IS NULL))",
                 name: "idx_expenses_on_active_source_payroll_period"
    add_index :expenses, %i[source_payroll_period_id unallocated],
              unique: true, where: "((source_payroll_period_id IS NOT NULL) AND (voided_at IS NULL))",
              name: "idx_expenses_on_active_source_payroll_period"
  end
end
