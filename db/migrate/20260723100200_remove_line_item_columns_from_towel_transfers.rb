class RemoveLineItemColumnsFromTowelTransfers < ActiveRecord::Migration[8.1]
  def up
    remove_reference :towel_transfers, :towel_type, foreign_key: true
    remove_column :towel_transfers, :declared_quantity
    remove_column :towel_transfers, :confirmed_quantity
  end

  def down
    add_reference :towel_transfers, :towel_type, foreign_key: true
    add_column :towel_transfers, :declared_quantity, :decimal, precision: 12, scale: 3
    add_column :towel_transfers, :confirmed_quantity, :decimal, precision: 12, scale: 3

    execute <<~SQL
      UPDATE towel_transfers t
      SET towel_type_id = i.towel_type_id,
          declared_quantity = i.declared_quantity,
          confirmed_quantity = i.confirmed_quantity
      FROM towel_transfer_items i
      WHERE i.towel_transfer_id = t.id
    SQL

    change_column_null :towel_transfers, :towel_type_id, false
    change_column_null :towel_transfers, :declared_quantity, false
  end
end
