class CreateLaundryBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :laundry_batches do |t|
      t.references :business,      null: false, foreign_key: true
      t.references :laundry_branch, null: false, foreign_key: { to_table: :branches }
      t.references :towel_type,    null: false, foreign_key: true

      t.string :batch_number, null: false
      t.string :status,       null: false, default: "draft"

      t.decimal :input_quantity,        precision: 12, scale: 3, null: false, default: 0
      t.decimal :output_clean_quantity, precision: 12, scale: 3, null: false, default: 0
      t.decimal :damaged_quantity,      precision: 12, scale: 3, null: false, default: 0
      t.decimal :disposed_quantity,     precision: 12, scale: 3, null: false, default: 0

      t.references :operator,     foreign_key: { to_table: :users }
      t.references :created_by,   foreign_key: { to_table: :users }
      t.references :completed_by, foreign_key: { to_table: :users }

      t.datetime :started_at
      t.datetime :completed_at
      t.text     :notes

      t.datetime :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text     :void_reason

      t.timestamps
    end

    add_index :laundry_batches, [ :business_id, :batch_number ], unique: true
    add_index :laundry_batches, :status
  end
end
