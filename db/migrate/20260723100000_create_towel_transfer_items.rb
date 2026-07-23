class CreateTowelTransferItems < ActiveRecord::Migration[8.1]
  def change
    create_table :towel_transfer_items do |t|
      t.references :towel_transfer, null: false, foreign_key: true
      t.references :towel_type,     null: false, foreign_key: true

      t.decimal :declared_quantity,  precision: 12, scale: 3, null: false
      t.decimal :confirmed_quantity, precision: 12, scale: 3

      t.timestamps
    end

    # A towel type can appear at most once per transfer — enforced at the DB
    # layer (mirrors RemainingDepositBalance's unique-index + service-level
    # guard convention), backing TowelTransferItem's uniqueness validation.
    add_index :towel_transfer_items, [ :towel_transfer_id, :towel_type_id ], unique: true,
              name: "index_towel_transfer_items_on_transfer_and_type"
  end
end
