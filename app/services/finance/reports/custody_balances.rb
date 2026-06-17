module Finance
  module Reports
    # Current balance of every active employee balance account, computed from
    # the ledger in a single grouped query (no N+1).
    class CustodyBalances
      def initialize(business)
        @business = business
      end

      def call
        accounts = @business.custody_accounts.active.includes(:user, :branch).ordered
        balances = CustodyTransaction.active
                                     .where(custody_account_id: accounts.map(&:id))
                                     .group(:custody_account_id).sum(:amount)

        rows = accounts.map do |account|
          { name:    account.name,
            holder:  account.user.full_name,
            branch:  account.branch&.name || "—",
            balance: balances[account.id] || 0 }
        end

        Table.new(
          title:   I18n.t("finance.reports.titles.custody_balances"),
          columns: [
            Column.new(key: :name,    label: I18n.t("finance.custody.accounts.name"), money: false),
            Column.new(key: :holder,  label: I18n.t("finance.custody.accounts.holder"), money: false),
            Column.new(key: :branch,  label: I18n.t("finance.custody.accounts.branch"), money: false),
            Column.new(key: :balance, label: I18n.t("finance.custody.accounts.balance"), money: true)
          ],
          rows:    rows,
          totals:  { balance: rows.sum { |r| r[:balance] } }
        )
      end
    end
  end
end
