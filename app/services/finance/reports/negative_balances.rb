module Finance
  module Reports
    # All active employee balance accounts that currently have a negative balance,
    # i.e. the company owes the employee money (they spent more than was topped up).
    class NegativeBalances
      def initialize(business)
        @business = business
      end

      def call
        accounts = @business.custody_accounts.active.includes(:user, :branch).ordered
        balances = CustodyTransaction.active
                                     .where(custody_account_id: accounts.map(&:id))
                                     .group(:custody_account_id).sum(:amount)

        rows = accounts.filter_map do |account|
          balance = balances[account.id] || 0
          next if balance >= 0

          { holder:  account.user.full_name,
            branch:  account.branch&.name || "—",
            balance: balance }
        end.sort_by { |r| r[:balance] }

        Table.new(
          title:   I18n.t("finance.reports.titles.negative_balances"),
          columns: [
            Column.new(key: :holder,  label: I18n.t("finance.custody.accounts.holder"),  money: false),
            Column.new(key: :branch,  label: I18n.t("finance.custody.accounts.branch"),  money: false),
            Column.new(key: :balance, label: I18n.t("finance.custody.accounts.balance"), money: true)
          ],
          rows:   rows,
          totals: { balance: rows.sum { |r| r[:balance] } }
        )
      end
    end
  end
end
