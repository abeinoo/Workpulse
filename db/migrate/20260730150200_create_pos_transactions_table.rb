class CreatePosTransactionsTable < ActiveRecord::Migration[8.1]
  def change
    create_table :pos_transactions do |t|
      t.references :pos_import, null: false, foreign_key: true
      t.references :business,   null: false, foreign_key: true
      t.references :branch,     null: false, foreign_key: true

      t.string   :transaction_id, null: false
      t.string   :reference_number
      t.decimal  :amount, precision: 12, scale: 2, null: false
      t.string   :payment_method
      t.string   :status, null: false
      t.datetime :transaction_date, null: false
      t.datetime :provider_created_at
      t.string   :terminal_id, null: false
      t.decimal  :fees,                 precision: 12, scale: 2, null: false, default: 0
      t.decimal  :administrative_fees,  precision: 12, scale: 2, null: false, default: 0

      t.timestamps
    end

    add_index :pos_transactions, [ :business_id, :transaction_id ], unique: true
    add_index :pos_transactions, :terminal_id
    add_index :pos_transactions, :transaction_date
    add_index :pos_transactions, :status
  end
end
