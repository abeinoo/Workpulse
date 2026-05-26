class AddAutoPayrollToBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :payroll_auto_generate_day, :integer, comment: "day-of-month to auto-generate (nil = disabled, 1-28)"
    add_column :businesses, :payroll_cutoff_day,        :integer, default: 0, null: false,
               comment: "attendance cutoff day for prior month (0 = end-of-month)"
  end
end
