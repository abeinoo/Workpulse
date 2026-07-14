class GeneralizeLaundryBatchConsumptions < ActiveRecord::Migration[8.1]
  def change
    # Closes the gap where material consumption could only ever be recorded
    # through a LaundryBatch (now hidden from normal navigation). A
    # consumption record is now either tied to a batch (laundry_branch_id
    # left nil, inferred from the batch) or standalone (laundry_branch_id
    # set directly) — never both, never neither; enforced in the model.
    change_column_null :laundry_batch_consumptions, :laundry_batch_id, true

    add_reference :laundry_batch_consumptions, :laundry_branch, foreign_key: { to_table: :branches }
  end
end
