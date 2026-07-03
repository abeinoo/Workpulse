class CreatePosTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :pos_transactions do |t|
      t.references :pos_import, null: false, foreign_key: true
      t.references :business,   null: false, foreign_key: true
      t.date       :transaction_date,    null: false
      t.string     :cashier_name,        null: false
      t.string     :payment_method_name, null: false
      t.decimal    :amount, precision: 15, scale: 4, null: false
      t.string     :reference_number
      t.string     :transaction_id
      t.jsonb      :raw_data, null: false, default: {}
      t.timestamps
    end

    add_index :pos_transactions, :cashier_name
    add_index :pos_transactions, :payment_method_name
    add_index :pos_transactions, :transaction_date
  end
end
