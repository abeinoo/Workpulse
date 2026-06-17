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

    def self.summarize(transactions)
      txns = transactions.to_a
      {
        top_ups:            txns.select(&:top_up?).sum(&:amount),
        expense_deductions: txns.select(&:expense_deduction?).sum(&:amount).abs,
        adjustments:        txns.select(&:adjustment?).sum(&:amount),
        transfers:          txns.select(&:transfer?).sum(&:amount),
        net:                txns.sum(&:amount)
      }
    end
  end
end
