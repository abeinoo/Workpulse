module Finance
  # Balance math for employee balance accounts. The authoritative balance is
  # always SUM of non-voided transaction amounts (stored signed).
  class CustodyBalance
    def initialize(account)
      @account = account
    end

    def current
      @account.custody_transactions.active.sum(:amount)
    end

    # The balance as it stood before the `count` newest transactions (by the
    # ledger's `recent` order, voided rows included in the count) — i.e. the
    # running balance to start from when page N of the ledger begins at that
    # offset. Pure read; derived from `current`, never stored.
    def excluding_newest(count)
      return current if count <= 0

      newest_ids = @account.custody_transactions.recent.limit(count).select(:id)
      current - @account.custody_transactions.active.where(id: newest_ids).sum(:amount)
    end

    def self.summarize(transactions)
      txns = transactions.to_a
      {
        top_ups:                      txns.select(&:top_up?).sum(&:amount),
        expense_deductions:           txns.select(&:expense_deduction?).sum(&:amount).abs,
        adjustments:                  txns.select(&:adjustment?).sum(&:amount),
        transfers:                    txns.select(&:transfer?).sum(&:amount),
        inventory_purchases:          txns.select(&:inventory_purchase?).sum(&:amount).abs,
        inventory_purchase_reversals: txns.select(&:inventory_purchase_reversal?).sum(&:amount),
        net:                          txns.sum(&:amount)
      }
    end
  end
end
