class AddNotesToRecurringExpenses < ActiveRecord::Migration[8.1]
  # Free-text notes on a recurring expense template (display only). Nullable
  # with no default: existing templates simply have no notes. Not copied onto
  # generated expenses — generation is unchanged.
  def change
    add_column :recurring_expenses, :notes, :text
  end
end
