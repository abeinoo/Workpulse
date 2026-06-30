class AddCancelledToTillHandovers < ActiveRecord::Migration[8.0]
  def change
    add_column :till_handovers, :cancelled_at,     :datetime
    add_column :till_handovers, :cancelled_by_id,  :bigint
    add_foreign_key :till_handovers, :users, column: :cancelled_by_id
    add_index :till_handovers, :cancelled_by_id
  end
end
