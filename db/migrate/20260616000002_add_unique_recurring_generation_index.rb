class AddUniqueRecurringGenerationIndex < ActiveRecord::Migration[8.1]
  # Hard DB-level guard against a recurring template generating two expenses for
  # the same scheduled date (each period has a distinct expense_date). This backs
  # up the row-lock in Finance::RecurringExpenseGenerator so a concurrent daily
  # job + manual "Generate Now" can never double-post a period.
  #
  # Partial (source_recurring_expense_id IS NOT NULL) so ordinary manual expenses
  # — which have no source — are unaffected and may share dates freely.
  def change
    add_index :expenses, [ :source_recurring_expense_id, :expense_date ],
              unique: true,
              where:  "source_recurring_expense_id IS NOT NULL",
              name:   "index_expenses_on_recurring_source_and_date"
  end
end
