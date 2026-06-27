class EvolveRemainingDepositBalancesForLedger < ActiveRecord::Migration[8.0]
  def up
    add_column :remaining_deposit_balances, :remaining_amount, :decimal, precision: 12, scale: 2
    add_column :remaining_deposit_balances, :closed_at, :datetime

    # Backfill snapshot: all records start with remaining = original amount...
    connection.execute(<<~SQL.squish)
      UPDATE remaining_deposit_balances SET remaining_amount = amount
    SQL
    # ...then zero out and timestamp the already-closed ones.
    connection.execute(<<~SQL.squish)
      UPDATE remaining_deposit_balances
         SET remaining_amount = 0,
             closed_at        = settled_at
       WHERE status IN ('settled', 'written_off')
    SQL

    change_column_null :remaining_deposit_balances, :remaining_amount, false

    say_with_time "seeding opening ledger transactions" do
      # One 'created' transaction per existing balance.
      connection.execute(<<~SQL.squish)
        INSERT INTO remaining_deposit_balance_transactions
          (remaining_deposit_balance_id, transaction_type, amount, performed_by_id, created_at)
        SELECT id, 'created', amount, created_by_id, created_at
          FROM remaining_deposit_balances
      SQL

      # One closure transaction for already-settled / written-off balances.
      connection.execute(<<~SQL.squish)
        INSERT INTO remaining_deposit_balance_transactions
          (remaining_deposit_balance_id, transaction_type, amount, performed_by_id, notes, created_at)
        SELECT id,
               CASE status WHEN 'written_off' THEN 'write_off' ELSE 'settlement' END,
               amount,
               settled_by_id,
               notes,
               COALESCE(settled_at, updated_at)
          FROM remaining_deposit_balances
         WHERE status IN ('settled', 'written_off')
           AND settled_by_id IS NOT NULL
      SQL
    end
  end

  def down
    connection.execute("DELETE FROM remaining_deposit_balance_transactions")
    remove_column :remaining_deposit_balances, :remaining_amount
    remove_column :remaining_deposit_balances, :closed_at
  end
end
