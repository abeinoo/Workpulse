class AddBusinessDayStartHourToBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :business_day_start_hour, :integer, default: 6, null: false
  end
end
