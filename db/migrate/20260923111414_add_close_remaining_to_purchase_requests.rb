class AddCloseRemainingToPurchaseRequests < ActiveRecord::Migration[8.1]
  # Supports the new partially_closed status: some quantity was received, and
  # the business explicitly decided not to pursue the rest. Mirrors the
  # existing approved_by/approved_at, rejected_by/rejected_at/rejection_reason
  # column shape already on this table — same actor/timestamp/reason pattern,
  # nothing new invented.
  def change
    change_table :purchase_requests, bulk: true do |t|
      t.datetime :closed_remaining_at
      t.references :closed_remaining_by, foreign_key: { to_table: :users }, null: true
      t.text :close_remaining_reason
    end
  end
end
