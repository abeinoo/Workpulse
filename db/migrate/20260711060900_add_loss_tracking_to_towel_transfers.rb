class AddLossTrackingToTowelTransfers < ActiveRecord::Migration[8.1]
  def change
    # Additive only. Loss/damage discovered during a laundry->branch return
    # transfer, tracked separately from declared/confirmed quantity so it can
    # never be double-counted against the transfer's own discrepancy.
    add_column :towel_transfers, :loss_quantity, :decimal, precision: 12, scale: 3, null: false, default: 0
    add_column :towel_transfers, :loss_reason, :string
  end
end
