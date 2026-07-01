class CreatePayrollAdjustmentEdits < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_adjustment_edits do |t|
      t.references :payroll_adjustment, null: false, foreign_key: true
      t.references :business,           null: false, foreign_key: true
      t.references :edited_by,          null: false, foreign_key: { to_table: :users }

      # Before-edit snapshot
      t.string  :old_adjustment_type, null: false
      t.decimal :old_amount,          null: false, precision: 10, scale: 2
      t.text    :old_reason
      t.integer :old_period_month,    null: false
      t.integer :old_period_year,     null: false

      # After-edit values
      t.string  :new_adjustment_type, null: false
      t.decimal :new_amount,          null: false, precision: 10, scale: 2
      t.text    :new_reason
      t.integer :new_period_month,    null: false
      t.integer :new_period_year,     null: false

      t.timestamps
    end
  end
end
