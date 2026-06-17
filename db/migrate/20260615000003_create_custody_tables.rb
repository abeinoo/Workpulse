class CreateCustodyTables < ActiveRecord::Migration[8.1]
  # Custody (العهد): cash floats held by ANY employee (branch/area/ops manager,
  # accountant, purchaser, storekeeper…), not just branch managers.
  #
  # Balance is always SUM of non-voided custody_transactions; current_balance is a
  # cache refreshed on every write. Transactions are voidable (never deleted) so
  # the ledger stays intact, mirroring the inventory-movement philosophy.
  #
  # Order matters for FKs: accounts → settlements → transactions, because a
  # transaction references the settlement that locks it. The self-referential
  # transfer_counterparty FK is added after the table exists.
  def change
    create_table :custody_accounts do |t|
      t.references :business, null: false, foreign_key: true
      t.references :user,     null: false, foreign_key: true
      t.references :branch,   foreign_key: true
      t.string  :name, null: false
      t.decimal :current_balance, precision: 12, scale: 2, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :custody_accounts, [ :business_id, :user_id, :name ], unique: true,
              name: "index_custody_accounts_on_business_user_and_name"

    create_table :custody_settlements do |t|
      t.references :business,        null: false, foreign_key: true
      t.references :custody_account, null: false, foreign_key: true
      t.string :settlement_number, null: false
      t.date   :period_start
      t.date   :period_end
      t.decimal :opening_balance, precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_funded,    precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_expenses,  precision: 12, scale: 2, null: false, default: 0
      t.decimal :total_returned,  precision: 12, scale: 2, null: false, default: 0
      t.decimal :cash_returned,   precision: 12, scale: 2, null: false, default: 0
      t.decimal :closing_balance, precision: 12, scale: 2, null: false, default: 0
      t.string  :status, null: false, default: "draft"
      t.references :submitted_by, foreign_key: { to_table: :users }
      t.references :reviewed_by,  foreign_key: { to_table: :users }
      t.datetime   :reviewed_at
      t.text       :rejection_reason
      t.text       :notes
      t.timestamps
    end
    add_index :custody_settlements, [ :business_id, :settlement_number ], unique: true

    create_table :custody_transactions do |t|
      t.references :business,          null: false, foreign_key: true
      t.references :custody_account,   null: false, foreign_key: true
      t.references :expense,           foreign_key: true
      t.references :custody_settlement, foreign_key: true
      t.bigint :transfer_counterparty_id

      t.string  :txn_type, null: false
      t.decimal :amount, precision: 12, scale: 2, null: false
      t.text    :notes

      t.references :created_by,  foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.datetime   :approved_at

      t.datetime   :voided_at
      t.references :voided_by, foreign_key: { to_table: :users }
      t.text       :void_reason

      t.timestamps
    end
    add_index :custody_transactions, [ :business_id, :txn_type ]
    add_index :custody_transactions, :transfer_counterparty_id
    add_foreign_key :custody_transactions, :custody_transactions,
                    column: :transfer_counterparty_id
  end
end
