class AddCancelledAtToDepositResponsibilityTransfers < ActiveRecord::Migration[8.0]
  def change
    add_column :deposit_responsibility_transfers, :cancelled_at, :datetime

    # Old index only excluded accepted records; now also exclude cancelled ones
    # so a new transfer can be created after cancellation.
    remove_index :deposit_responsibility_transfers, name: "idx_drt_one_pending_per_dr"
    add_index :deposit_responsibility_transfers, :daily_reconciliation_id,
              where: "accepted_at IS NULL AND cancelled_at IS NULL",
              unique: true,
              name:   "idx_drt_one_pending_per_dr"
  end
end
