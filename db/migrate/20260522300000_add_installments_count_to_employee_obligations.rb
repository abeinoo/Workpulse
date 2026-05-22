class AddInstallmentsCountToEmployeeObligations < ActiveRecord::Migration[8.1]
  def up
    add_column :employee_obligations, :installments_count, :integer

    # Backfill: derive count from total / installment for existing rows
    execute <<~SQL
      UPDATE employee_obligations
      SET installments_count = CEIL(total_amount::numeric / NULLIF(installment_amount, 0)::numeric)
      WHERE installment_amount > 0 AND total_amount > 0;
    SQL

    # Fallback for any rows that couldn't be derived
    execute "UPDATE employee_obligations SET installments_count = 1 WHERE installments_count IS NULL"

    change_column_null :employee_obligations, :installments_count, false
    change_column_default :employee_obligations, :installments_count, 1
  end

  def down
    remove_column :employee_obligations, :installments_count
  end
end
