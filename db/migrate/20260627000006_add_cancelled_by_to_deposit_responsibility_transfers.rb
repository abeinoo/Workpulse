class AddCancelledByToDepositResponsibilityTransfers < ActiveRecord::Migration[8.0]
  def change
    add_reference :deposit_responsibility_transfers, :cancelled_by,
                  foreign_key: { to_table: :users },
                  null: true
  end
end
