class AddOvertimeGraceMinutesToBusinesses < ActiveRecord::Migration[8.1]
  def change
    add_column :businesses, :overtime_grace_minutes, :integer, default: 0, null: false
  end
end
