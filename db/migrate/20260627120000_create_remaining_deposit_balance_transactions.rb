class CreateRemainingDepositBalanceTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :remaining_deposit_balance_transactions do |t|
      t.references :remaining_deposit_balance, null: false,
                   foreign_key: true, index: { name: "idx_rdbt_on_rdb_id" }
      t.string  :transaction_type, null: false
      t.decimal :amount, precision: 12, scale: 2
      t.references :performed_by, null: false,
                   foreign_key: { to_table: :users }, index: { name: "idx_rdbt_on_performed_by_id" }
      t.references :previous_responsible_user, null: true,
                   foreign_key: { to_table: :users }, index: { name: "idx_rdbt_on_prev_user_id" }
      t.references :new_responsible_user, null: true,
                   foreign_key: { to_table: :users }, index: { name: "idx_rdbt_on_new_user_id" }
      t.text    :notes
      t.datetime :created_at, null: false
    end

    add_index :remaining_deposit_balance_transactions, :transaction_type,
              name: "idx_rdbt_on_type"
  end
end
