class CreateTowelTransfers < ActiveRecord::Migration[8.1]
  def change
    create_table :towel_transfers do |t|
      t.references :business,            null: false, foreign_key: true
      t.references :towel_type,          null: false, foreign_key: true
      t.references :source_branch,       null: false, foreign_key: { to_table: :branches }
      t.references :destination_branch,  null: false, foreign_key: { to_table: :branches }

      t.string   :status,        null: false, default: "draft"
      # The physical condition of the towels being moved: clean or dirty.
      t.string   :towel_status,  null: false
      t.decimal  :declared_quantity,  precision: 12, scale: 3, null: false
      t.decimal  :confirmed_quantity, precision: 12, scale: 3

      t.references :created_by,    foreign_key: { to_table: :users }
      t.references :dispatched_by, foreign_key: { to_table: :users }
      t.references :received_by,   foreign_key: { to_table: :users }
      t.references :cancelled_by,  foreign_key: { to_table: :users }

      t.datetime :dispatched_at
      t.datetime :received_at
      t.datetime :cancelled_at
      t.text     :cancellation_reason
      t.text     :notes

      t.timestamps
    end

    add_index :towel_transfers, :status
    add_index :towel_transfers, [ :business_id, :status ]
  end
end
