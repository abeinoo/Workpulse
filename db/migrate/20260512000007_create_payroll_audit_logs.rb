class CreatePayrollAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :payroll_audit_logs do |t|
      t.references :payroll_period, null: false, foreign_key: true
      t.references :actor,          null: false, foreign_key: { to_table: :users }
      t.string     :action_type,    null: false
      t.string     :from_status
      t.string     :to_status
      t.text        :metadata
      t.timestamps
    end

    add_index :payroll_audit_logs, :action_type
  end
end
