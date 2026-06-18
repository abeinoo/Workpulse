class AddCancellationFieldsToBalanceRequests < ActiveRecord::Migration[8.1]
  def change
    add_reference :balance_requests, :cancelled_by, foreign_key: { to_table: :users }, null: true
    add_column    :balance_requests, :cancelled_at,        :datetime
    add_column    :balance_requests, :cancellation_reason, :text
  end
end
