class CreateTillRefunds < ActiveRecord::Migration[8.0]
  def change
    create_table :till_refunds do |t|
      t.bigint   :daily_reconciliation_id, null: false
      t.bigint   :payment_method_id,       null: false
      t.bigint   :processed_by_id,         null: false
      t.decimal  :amount, precision: 12, scale: 2, null: false
      t.datetime :refunded_at, null: false
      t.text     :notes
      t.string   :idempotency_key

      t.timestamps
    end

    add_index :till_refunds, :daily_reconciliation_id, name: "index_till_refunds_on_dr_id"
    add_index :till_refunds, :payment_method_id
    add_index :till_refunds, :processed_by_id
    add_index :till_refunds, :idempotency_key, unique: true, where: "idempotency_key IS NOT NULL"

    add_foreign_key :till_refunds, :daily_reconciliations
    add_foreign_key :till_refunds, :payment_methods
    add_foreign_key :till_refunds, :users, column: :processed_by_id
  end
end
