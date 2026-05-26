class AddPerformanceIndexes < ActiveRecord::Migration[8.1]
  def change
    # Speeds up business-scoped period lookups (dashboard, auto-gen)
    add_index :payroll_periods, [ :business_id, :period_year, :period_month ],
              name: "idx_payroll_periods_business_ym", unique: true, if_not_exists: true

    # Speeds up attendance anomaly detection window queries
    add_index :attendance_records, [ :user_id, :work_date ],
              name: "idx_att_records_user_date", if_not_exists: true
    add_index :attendance_records, [ :user_id, :status ],
              name: "idx_att_records_user_status", if_not_exists: true

    # Speeds up payroll entry aggregates by period
    add_index :payroll_entries, :payroll_period_id, if_not_exists: true

    # Speeds up pending-count queries on line items and adjustments
    add_index :payroll_line_items,    [ :payroll_entry_id, :review_status ],
              name: "idx_payroll_line_items_entry_status", if_not_exists: true
    add_index :payroll_adjustments,   [ :payroll_period_id, :review_status ],
              name: "idx_payroll_adj_period_status", if_not_exists: true
  end
end
