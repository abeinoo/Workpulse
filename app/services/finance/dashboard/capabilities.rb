module Finance
  module Dashboard
    # Widgets that depend on data models this app doesn't have yet (multi-business
    # membership, supplier financials, standalone cash/bank ledgers) must not be
    # hard-coded off — they gate on whether the backing table actually exists, so
    # they switch on automatically the day that table is migrated in, with no
    # dashboard code changes required.
    #
    # Every predicate here is false today. Do not fabricate a value for any of
    # them from unrelated data (e.g. custody balances are NOT a cash balance).
    class Capabilities
      def multi_business?
        table_exists?("business_memberships")
      end

      def supplier_financials_available?
        table_exists?("supplier_invoices")
      end

      def cash_ledger_available?
        table_exists?("cash_accounts")
      end

      def bank_ledger_available?
        table_exists?("bank_accounts")
      end

      private

      def table_exists?(name)
        ActiveRecord::Base.connection.table_exists?(name)
      end
    end
  end
end
