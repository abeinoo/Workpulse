class AddBulkFieldsToPayrollAdjustments < ActiveRecord::Migration[8.0]
  def change
    add_column :payroll_adjustments, :bulk_batch_id,  :string
    add_column :payroll_adjustments, :import_source,  :string, default: "manual", null: false

    add_index :payroll_adjustments, :bulk_batch_id
  end
end
