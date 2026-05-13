class CreatePayrollEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_entries do |t|
      t.references :payroll_period, null: false, foreign_key: true
      t.references :user,           null: false, foreign_key: true
      t.string  :salary_type,       null: false
      t.decimal :base_salary,       precision: 12, scale: 2, null: false
      t.integer :working_days,      null: false
      t.integer :days_worked,       null: false, default: 0
      t.decimal :total_deductions,  precision: 12, scale: 2, null: false, default: "0"
      t.decimal :total_overtime,    precision: 12, scale: 2, null: false, default: "0"
      t.decimal :total_bonuses,     precision: 12, scale: 2, null: false, default: "0"
      t.decimal :advances_deducted, precision: 12, scale: 2, null: false, default: "0"
      t.decimal :net_salary,        precision: 12, scale: 2, null: false
      t.string  :status,            null: false, default: "draft"
      t.text    :notes
      t.timestamps
    end

    add_index :payroll_entries, [ :payroll_period_id, :user_id ], unique: true
    add_index :payroll_entries, [ :user_id, :status ]
  end
end
