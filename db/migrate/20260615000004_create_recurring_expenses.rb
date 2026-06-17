class CreateRecurringExpenses < ActiveRecord::Migration[8.1]
  # Templates that auto-generate PENDING expenses when due (rent, internet,
  # cleaning contract…). A daily job reads next_run_on and creates a
  # pending_approval Expense — never auto-paid. recurring_expense_allocations
  # mirror expense_allocations so a recurring shared expense reproduces its split.
  #
  # Also wires expenses.source_recurring_expense_id (attribution of generated
  # expenses back to their template), added here now that recurring_expenses exists.
  def change
    create_table :recurring_expenses do |t|
      t.references :business,         null: false, foreign_key: true
      t.references :branch,           foreign_key: true
      t.references :expense_category, null: false, foreign_key: true
      t.references :expense_type,     foreign_key: true

      t.decimal :amount, precision: 12, scale: 2, null: false
      t.string  :frequency, null: false
      t.date    :start_date, null: false
      t.date    :end_date
      t.date    :next_run_on, null: false
      t.date    :last_generated_on
      t.string  :vendor_name
      t.text    :description
      t.boolean :active, null: false, default: true

      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :recurring_expenses, [ :business_id, :active, :next_run_on ]

    create_table :recurring_expense_allocations do |t|
      t.references :recurring_expense, null: false, foreign_key: true
      t.references :branch,            null: false, foreign_key: true
      t.decimal :allocation_percentage, precision: 5, scale: 2, null: false, default: 0
      t.timestamps
    end
    add_index :recurring_expense_allocations, [ :recurring_expense_id, :branch_id ],
              unique: true, name: "index_recurring_allocations_on_recurring_and_branch"

    add_reference :expenses, :source_recurring_expense,
                  foreign_key: { to_table: :recurring_expenses }, index: true
  end
end
