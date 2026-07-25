class CreateBankDisputes < ActiveRecord::Migration[8.1]
  def change
    create_table :bank_disputes do |t|
      t.references :till_deposit, null: false, foreign_key: true
      t.references :business,     null: false, foreign_key: true
      t.references :branch,      null: false, foreign_key: true
      t.references :opened_by,   null: false, foreign_key: { to_table: :users }

      t.string :status, null: false, default: "new"

      t.date     :transaction_date, null: false
      t.time     :transaction_time
      t.decimal  :amount, precision: 12, scale: 2, null: false
      t.string   :bank_name, null: false
      t.string   :terminal_id, null: false
      t.string   :merchant_id
      t.string   :card_last4, limit: 4
      t.string   :reference_number
      t.string   :stan
      t.string   :authorization_code

      t.string   :bank_ticket_number
      t.datetime :opened_at, null: false
      t.text     :notes

      t.timestamps
    end

    add_index :bank_disputes, :status
    add_index :bank_disputes, [ :till_deposit_id, :status ]
  end
end
