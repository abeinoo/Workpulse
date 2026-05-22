class AddSalaryAdvancePercentageToBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :max_salary_advance_percentage, :decimal,
               precision: 5, scale: 2
  end
end
