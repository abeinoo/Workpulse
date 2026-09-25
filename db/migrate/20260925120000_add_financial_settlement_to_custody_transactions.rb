class AddFinancialSettlementToCustodyTransactions < ActiveRecord::Migration[8.0]
  # Direct link from the custody movement to the exact FinancialSettlement row
  # that caused it (original payment → its debit; reversal → its credit). Same
  # shape as the existing expense_id link: a specific FK alongside the generic
  # polymorphic #source (which keeps pointing at the GoodsReceipt). The unique
  # index guarantees one custody movement per settlement. Balance math
  # (SUM(amount) over non-voided rows) is unaffected.
  def up
    add_reference :custody_transactions, :financial_settlement,
                  foreign_key: true, index: { unique: true }

    # Backfill goods-receipt custody movements: the nth movement of a given
    # (receipt, account, signed amount) pairs with the nth settlement of the
    # same receipt/account whose amount is its exact opposite, in id order.
    execute <<~SQL
      WITH txns AS (
        SELECT id, source_id, custody_account_id, amount,
               ROW_NUMBER() OVER (PARTITION BY source_id, custody_account_id, amount ORDER BY id) AS rn
          FROM custody_transactions
         WHERE source_type = 'GoodsReceipt'
           AND txn_type IN ('inventory_purchase', 'inventory_purchase_reversal')
      ),
      settlements AS (
        SELECT id, settleable_id, funding_source_id, -amount AS amount,
               ROW_NUMBER() OVER (PARTITION BY settleable_id, funding_source_id, amount ORDER BY id) AS rn
          FROM financial_settlements
         WHERE settleable_type = 'GoodsReceipt'
           AND funding_source_type = 'CustodyAccount'
      )
      UPDATE custody_transactions ct
         SET financial_settlement_id = s.id
        FROM txns t
        JOIN settlements s
          ON s.settleable_id     = t.source_id
         AND s.funding_source_id = t.custody_account_id
         AND s.amount            = t.amount
         AND s.rn                = t.rn
       WHERE ct.id = t.id
    SQL
  end

  def down
    remove_reference :custody_transactions, :financial_settlement, foreign_key: true, index: { unique: true }
  end
end
