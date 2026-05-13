class UpdatePayrollPeriodsReviewWorkflow < ActiveRecord::Migration[8.1]
  def up
    # Migrate any existing 'approved' status rows to 'finalized'
    execute "UPDATE payroll_periods SET status = 'finalized' WHERE status = 'approved'"

    remove_foreign_key :payroll_periods, column: :approved_by_id
    rename_column :payroll_periods, :approved_by_id, :finalized_by_id
    rename_column :payroll_periods, :approved_at,    :finalized_at

    remove_index :payroll_periods, :approved_by_id, if_exists: true
    add_index :payroll_periods, :finalized_by_id, if_not_exists: true
    add_foreign_key :payroll_periods, :users, column: :finalized_by_id
  end

  def down
    execute "UPDATE payroll_periods SET status = 'approved' WHERE status = 'finalized'"
    execute "UPDATE payroll_periods SET status = 'under_review' WHERE status = 'branch_review_completed'"

    remove_foreign_key :payroll_periods, column: :finalized_by_id
    remove_index :payroll_periods, :finalized_by_id, if_exists: true
    rename_column :payroll_periods, :finalized_by_id, :approved_by_id
    rename_column :payroll_periods, :finalized_at,    :approved_at
    add_index :payroll_periods, :approved_by_id
    add_foreign_key :payroll_periods, :users, column: :approved_by_id
  end
end
