class CreateBranchRevenues < ActiveRecord::Migration[8.1]
  # Manual monthly revenue entry per branch — the revenue input for branch
  # profitability (the app has no sales/POS source). period_month is normalized to
  # the first day of the month; one row per branch per month.
  def change
    create_table :branch_revenues do |t|
      t.references :business, null: false, foreign_key: true
      t.references :branch,   null: false, foreign_key: true
      t.date    :period_month, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false, default: 0
      t.text    :notes
      t.references :created_by, foreign_key: { to_table: :users }
      t.timestamps
    end
    add_index :branch_revenues, [ :branch_id, :period_month ], unique: true
  end
end
