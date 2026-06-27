class CreateEmployeeReconciliationSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :employee_reconciliation_summaries do |t|
      t.references :daily_reconciliation, null: false, foreign_key: true
      t.references :user,                 null: false, foreign_key: true
      t.datetime   :computed_at,          null: false
      t.timestamps

      t.index [:daily_reconciliation_id, :user_id],
              unique: true,
              name: "idx_emp_recon_summaries_unique_per_dr_user"
    end

    create_table :employee_reconciliation_summary_amounts do |t|
      t.references :employee_reconciliation_summary, null: false, foreign_key: true
      t.references :payment_method,                  null: false, foreign_key: true
      t.string     :payment_method_name,             null: false
      t.decimal    :collected_amount, precision: 12, scale: 2, default: "0.0", null: false
      t.decimal    :refund_amount,    precision: 12, scale: 2, default: "0.0", null: false
      t.timestamps

      t.index [:employee_reconciliation_summary_id, :payment_method_id],
              unique: true,
              name: "idx_emp_recon_amounts_unique_per_summary_pm"
    end
  end
end
