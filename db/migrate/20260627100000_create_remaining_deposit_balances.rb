class CreateRemainingDepositBalances < ActiveRecord::Migration[8.0]
  def change
    create_table :remaining_deposit_balances do |t|
      # Aggregate root
      t.references :daily_reconciliation, null: false, foreign_key: true,
                   index: { name: "index_rdb_on_daily_reconciliation_id" }

      # The deposit that generated this remaining balance (nullable — may be created manually)
      t.references :till_deposit, null: true, foreign_key: true,
                   index: { name: "index_rdb_on_till_deposit_id" }

      # The deposit that settled this balance (nullable until settled)
      t.references :settled_by_deposit, null: true,
                   foreign_key: { to_table: :till_deposits },
                   index: { name: "index_rdb_on_settled_by_deposit_id" }

      # People
      t.references :responsible_user, null: false, foreign_key: { to_table: :users },
                   index: { name: "index_rdb_on_responsible_user_id" }
      t.references :settled_by, null: true, foreign_key: { to_table: :users },
                   index: { name: "index_rdb_on_settled_by_id" }
      t.references :created_by, null: false, foreign_key: { to_table: :users },
                   index: { name: "index_rdb_on_created_by_id" }

      # Denormalised for efficient scoping — avoids joins on hot accountant queries
      t.references :business, null: false, foreign_key: true,
                   index: { name: "index_rdb_on_business_id" }
      t.references :branch,   null: false, foreign_key: true,
                   index: { name: "index_rdb_on_branch_id" }

      t.decimal :amount, precision: 12, scale: 2, null: false
      t.string  :status, null: false, default: "open"

      t.text     :notes
      t.datetime :settled_at

      t.timestamps
    end

    add_index :remaining_deposit_balances, :status,
              name: "index_rdb_on_status"
    add_index :remaining_deposit_balances, [ :business_id, :status ],
              name: "index_rdb_on_business_and_status"
  end
end
