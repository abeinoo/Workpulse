class AddCancellationFieldsToEmployeeRequests < ActiveRecord::Migration[8.1]
  def change
    add_reference :employee_requests, :cancelled_by, foreign_key: { to_table: :users }, null: true
    add_column    :employee_requests, :cancelled_at,                :datetime
    add_column    :employee_requests, :cancellation_reason,         :text
    # Punch-correction source snapshots — stored at approval time so cancellation
    # can restore the exact pre-correction state of the attendance record.
    add_column    :employee_requests, :original_check_in_source,    :string
    add_column    :employee_requests, :original_check_out_source,   :string
  end
end
