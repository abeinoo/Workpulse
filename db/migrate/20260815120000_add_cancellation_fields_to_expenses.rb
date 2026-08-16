class AddCancellationFieldsToExpenses < ActiveRecord::Migration[7.1]
  def change
    add_column :expenses, :cancelled_at, :datetime
    add_column :expenses, :cancelled_by_id, :bigint
    add_column :expenses, :cancellation_reason, :text

    add_index :expenses, :cancelled_by_id
    add_foreign_key :expenses, :users, column: :cancelled_by_id
  end
end
