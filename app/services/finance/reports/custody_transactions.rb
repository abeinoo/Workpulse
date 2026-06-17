module Finance
  module Reports
    # Balance transaction ledger across all accounts within a date range
    # (non-voided), newest first.
    class CustodyTransactions
      def initialize(business, from:, to:)
        @business = business
        @from     = from
        @to       = to
      end

      def call
        txns = @business.custody_transactions.active
                        .where(created_at: @from.beginning_of_day..@to.end_of_day)
                        .includes(:custody_account).recent

        rows = txns.map do |txn|
          { date:    I18n.l(txn.created_at.to_date, format: :long),
            account: txn.custody_account.name,
            type:    I18n.t("finance.custody.transactions.types.#{txn.txn_type}"),
            amount:  txn.amount,
            notes:   txn.notes.presence || "—" }
        end

        Table.new(
          title:   I18n.t("finance.reports.titles.custody_transactions"),
          columns: [
            Column.new(key: :date,    label: I18n.t("finance.expenses.date"), money: false),
            Column.new(key: :account, label: I18n.t("finance.custody.accounts.name"), money: false),
            Column.new(key: :type,    label: I18n.t("finance.custody.transactions.type"), money: false),
            Column.new(key: :amount,  label: I18n.t("finance.custody.transactions.amount"), money: true),
            Column.new(key: :notes,   label: I18n.t("finance.common.notes"), money: false)
          ],
          rows:    rows,
          totals:  { amount: rows.sum { |r| r[:amount] } }
        )
      end
    end
  end
end
