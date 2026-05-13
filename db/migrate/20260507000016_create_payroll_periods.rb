class CreatePayrollPeriods < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_periods do |t|
      t.references :business,     null: false, foreign_key: true
      t.references :branch,       foreign_key: true
      t.references :generated_by, foreign_key: { to_table: :users }
      t.references :approved_by,  foreign_key: { to_table: :users }
      t.integer  :period_year,    null: false
      t.integer  :period_month,   null: false
      t.integer  :working_days,   null: false
      t.string   :status,         null: false, default: "draft"
      t.datetime :generated_at
      t.datetime :approved_at
      t.timestamps
    end

    add_index :payroll_periods, [ :business_id, :branch_id, :period_year, :period_month ],
              name: "index_payroll_periods_unique"
  end
end
