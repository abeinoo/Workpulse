class EvolvePayrollAdjustments < ActiveRecord::Migration[8.1]
  def up
    # Make payroll_period_id optional — standalone adjustments have no period yet.
    change_column_null :payroll_adjustments, :payroll_period_id, true

    # Period identification for standalone adjustments.
    add_reference :payroll_adjustments, :business, null: true, foreign_key: true
    add_column    :payroll_adjustments, :period_month, :integer
    add_column    :payroll_adjustments, :period_year,  :integer

    # Granular audit trail (created_by already exists; add per-action actors).
    add_reference :payroll_adjustments, :approved_by, foreign_key: { to_table: :users }, null: true
    add_column    :payroll_adjustments, :approved_at,  :datetime
    add_reference :payroll_adjustments, :rejected_by, foreign_key: { to_table: :users }, null: true
    add_column    :payroll_adjustments, :rejected_at,  :datetime

    # Backfill existing records — derive business/period from their payroll_period.
    execute <<~SQL
      UPDATE payroll_adjustments
      SET
        business_id  = (SELECT business_id  FROM payroll_periods WHERE id = payroll_adjustments.payroll_period_id),
        period_month = (SELECT period_month  FROM payroll_periods WHERE id = payroll_adjustments.payroll_period_id),
        period_year  = (SELECT period_year   FROM payroll_periods WHERE id = payroll_adjustments.payroll_period_id)
      WHERE payroll_period_id IS NOT NULL
    SQL

    change_column_null :payroll_adjustments, :business_id,  false
    change_column_null :payroll_adjustments, :period_month, false
    change_column_null :payroll_adjustments, :period_year,  false

    add_index :payroll_adjustments,
              [ :business_id, :period_year, :period_month, :user_id ],
              name: "index_payroll_adjustments_on_period_and_user"
  end

  def down
    remove_index  :payroll_adjustments, name: "index_payroll_adjustments_on_period_and_user"
    remove_column :payroll_adjustments, :rejected_at
    remove_reference :payroll_adjustments, :rejected_by, foreign_key: { to_table: :users }
    remove_column :payroll_adjustments, :approved_at
    remove_reference :payroll_adjustments, :approved_by, foreign_key: { to_table: :users }
    remove_column :payroll_adjustments, :period_year
    remove_column :payroll_adjustments, :period_month
    remove_reference :payroll_adjustments, :business, foreign_key: true
    change_column_null :payroll_adjustments, :payroll_period_id, false
  end
end
