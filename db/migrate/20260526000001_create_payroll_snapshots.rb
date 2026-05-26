class CreatePayrollSnapshots < ActiveRecord::Migration[8.0]
  def change
    create_table :payroll_snapshots do |t|
      t.references :payroll_period, null: false, foreign_key: true
      t.references :taken_by,       null: false, foreign_key: { to_table: :users }
      t.string  :trigger,           null: false, default: "pre_regenerate"
      t.integer :employee_count,    null: false, default: 0
      t.decimal :total_net,         precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_base,        precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_overtime,    precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_deductions,  precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_bonuses,     precision: 12, scale: 2, null: false, default: 0
      t.jsonb   :employee_details,  null: false, default: {}
      t.timestamps
    end

    add_index :payroll_snapshots, [ :payroll_period_id, :created_at ]
  end
end
