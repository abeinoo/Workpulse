class RemoveLossFieldsFromTowelTransfers < ActiveRecord::Migration[8.1]
  def up
    raise ActiveRecord::IrreversibleMigration, "loss_quantity has real values" if
      execute("SELECT 1 FROM towel_transfers WHERE loss_quantity > 0 LIMIT 1").any?

    remove_column :towel_transfers, :loss_quantity
    remove_column :towel_transfers, :loss_reason
  end

  def down
    add_column :towel_transfers, :loss_quantity, :decimal, precision: 12, scale: 3, default: "0.0", null: false
    add_column :towel_transfers, :loss_reason, :string
  end
end
