class CreateObligationPostponements < ActiveRecord::Migration[8.1]
  def change
    create_table :obligation_postponements do |t|
      t.references :employee_obligation, null: false, foreign_key: true
      t.references :performed_by,        null: false, foreign_key: { to_table: :users }

      # "next_month"  — the amount moves onto the immediately following installment.
      # "extend_loan" — the amount is relocated to a brand-new installment appended
      #                 after the current end of the schedule.
      t.string  :postponement_type, null: false

      # The installment being postponed — never re-deducted at this period.
      t.integer :original_month, null: false
      t.integer :original_year,  null: false
      t.decimal :original_amount, precision: 12, scale: 2, null: false

      # Where the amount was moved to (existing next installment, or the new
      # appended one for extend_loan).
      t.integer :target_month, null: false
      t.integer :target_year,  null: false
      t.decimal :amount, precision: 12, scale: 2, null: false

      t.text :reason

      t.timestamps
    end

    # An installment can only be postponed once — see EmployeeObligation#postponable?.
    add_index :obligation_postponements,
              [ :employee_obligation_id, :original_year, :original_month ],
              unique: true,
              name:   "idx_obligation_postponements_unique_original"
  end
end
