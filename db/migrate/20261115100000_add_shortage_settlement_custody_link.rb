# Bulk settlement of Remaining Deposit Balances (cash shortages) into a
# selected employee's Custody Account — the "Shortage Settlement Deposit".
#
# 1. remaining_deposit_balance_transactions.custody_transaction_id — the
#    shortage's own "settlement" ledger row names the exact custody credit it
#    produced, so the settlement is distinguishable from one made through a
#    payment method (cash / card / bank) without inferring anything. Unique:
#    one custody credit settles at most one ledger row.
# 2. A partial unique index on custody_transactions: at most ONE active
#    shortage_settlement_deposit per RemainingDepositBalance. This is the
#    database backstop against a duplicate credit (double submit, two users
#    settling overlapping days at the same time).
#
# Purely additive — no existing row is read or changed.
#
# Rollback: reversible (drops the index, the FK, the index on the column and the
# column). Safe only while no Shortage Settlement Deposit exists: once one has
# been posted, rolling back deletes the ledger row → custody credit link — roll
# forward instead.
class AddShortageSettlementCustodyLink < ActiveRecord::Migration[8.1]
  def change
    add_reference :remaining_deposit_balance_transactions, :custody_transaction,
                  null: true, foreign_key: true,
                  index: { unique: true, name: "idx_rdbt_on_custody_transaction_id" }

    add_index :custody_transactions, :source_id,
              unique: true,
              where:  "txn_type = 'shortage_settlement_deposit' " \
                      "AND source_type = 'RemainingDepositBalance' AND voided_at IS NULL",
              name:   "idx_custody_txn_one_active_shortage_settlement"
  end
end
