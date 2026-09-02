class AddIgnoreFieldsToTillDeposits < ActiveRecord::Migration[7.1]
  def change
    add_column :till_deposits, :ignored_at, :datetime
    add_column :till_deposits, :ignored_by_id, :bigint
    add_column :till_deposits, :ignore_reason, :text

    add_index :till_deposits, :ignored_by_id
    add_foreign_key :till_deposits, :users, column: :ignored_by_id
  end
end
