class AddWorkingDaysToBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :working_days_per_month, :integer, null: false, default: 26
  end
end
