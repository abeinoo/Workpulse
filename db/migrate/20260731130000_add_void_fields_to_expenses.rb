class AddVoidFieldsToExpenses < ActiveRecord::Migration[8.1]
  # Repair migration. db/schema.rb has declared expenses.voided_at/voided_by_id/
  # void_reason since commit aa5d5e5 ("expense", 2026-06-17), which introduced the
  # entire Finance module — but no migration anywhere in this repository's history
  # ever created them. Traced exhaustively:
  #   - git log --diff-filter=D -- db/migrate/  → zero migrations ever deleted.
  #   - git log --diff-filter=R -- db/migrate/  → zero migrations ever renamed.
  #   - Every migration touching `expenses` (20260615000002_create_expenses_and_
  #     allocations, 20260616000001_add_vendor_reference_to_expenses,
  #     20260617000001_add_custody_account_to_expenses, 20260617000002_add_
  #     payment_type_to_expenses, 20260617000003_redesign_expense_balance_model,
  #     20260617000006_add_deduct_from_balance_to_expenses, and every later one)
  #     inspected individually — none add void_at/voided_by_id/void_reason.
  # Conclusion: db/schema.rb was directly hand-edited (or dumped from a database
  # that had these columns added out-of-band, e.g. via console) in that commit,
  # without ever committing the migration that should have produced them. This
  # is genuine schema/migration-history drift, not a deletion or a squash.
  #
  # Guarded with `unless column_exists?` because we don't know whether every
  # environment is missing these columns (e.g. production may already have them
  # from whatever out-of-band change put them in schema.rb in the first place) —
  # this repair must be a no-op wherever they already exist, and additive
  # wherever they don't, so it converges every environment to the same schema
  # regardless of its starting point.
  def change
    unless column_exists?(:expenses, :voided_at)
      add_column :expenses, :voided_at, :datetime
    end

    unless column_exists?(:expenses, :voided_by_id)
      add_reference :expenses, :voided_by, foreign_key: { to_table: :users }, index: true
    end

    unless column_exists?(:expenses, :void_reason)
      add_column :expenses, :void_reason, :text
    end
  end
end
