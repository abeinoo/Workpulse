class MakeAuditLogPeriodNullable < ActiveRecord::Migration[8.1]
  def change
    change_column_null :payroll_audit_logs, :payroll_period_id, true
  end
end
