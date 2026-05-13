class CreatePayrollAdjustments < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_adjustments do |t|
      t.references :payroll_period, null: false, foreign_key: true
      t.references :user,           null: false, foreign_key: true
      t.references :created_by,     null: false, foreign_key: { to_table: :users }
      t.string  :adjustment_type, null: false
      t.decimal :amount,          precision: 12, scale: 2, null: false
      t.string  :reason,          null: false
      t.timestamps
    end

    add_index :payroll_adjustments, [ :payroll_period_id, :user_id ]
  end
end
