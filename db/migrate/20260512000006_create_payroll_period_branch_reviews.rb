class CreatePayrollPeriodBranchReviews < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_period_branch_reviews do |t|
      t.references :payroll_period, null: false, foreign_key: true
      t.references :branch,         null: false, foreign_key: true
      t.references :reviewer,       null: false, foreign_key: { to_table: :users }
      t.string     :status,         null: false, default: "pending"
      t.datetime   :completed_at
      t.text        :notes
      t.timestamps
    end

    add_index :payroll_period_branch_reviews,
              [ :payroll_period_id, :branch_id ],
              unique: true,
              name: "index_payroll_period_branch_reviews_unique"
  end
end
