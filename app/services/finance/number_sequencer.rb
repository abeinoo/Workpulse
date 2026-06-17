module Finance
  # Per-business sequential document numbers for financial documents
  # (e.g. "EXP-000123", "STL-000123"). Race-safe via a transaction-level Postgres
  # advisory lock keyed by business + document kind — the same mechanism as
  # Inventory::NumberSequencer. Must be called inside the transaction that
  # persists the document so the lock is held until COMMIT; the per-business
  # unique index on the number column is the final backstop.
  class NumberSequencer
    # Advisory-lock namespaces, distinct from inventory's (4101–4105).
    LOCK_NAMESPACES = { expense: 4201, balance_request: 4203 }.freeze

    CONFIG = {
      expense:         { model: "Expense",         column: :reference_number, prefix: "EXP" },
      balance_request: { model: "BalanceRequest",  column: :reference_number, prefix: "BRQ" }
    }.freeze

    PAD = 6

    def initialize(business, kind)
      @business = business
      @kind     = kind.to_sym
      @config   = CONFIG.fetch(@kind)
    end

    def next_number
      acquire_lock
      "#{@config[:prefix]}-#{format("%0#{PAD}d", next_sequence)}"
    end

    private

    def acquire_lock
      ActiveRecord::Base.connection.execute(
        "SELECT pg_advisory_xact_lock(#{LOCK_NAMESPACES.fetch(@kind)}, #{@business.id.to_i})"
      )
    end

    def next_sequence
      model  = @config[:model].constantize
      column = @config[:column]
      prefix = "#{@config[:prefix]}-"

      highest = model.where(business: @business)
                     .where("#{column} LIKE ?", "#{prefix}%")
                     .pluck(column)
                     .filter_map { |n| n.delete_prefix(prefix)[/\A\d+\z/]&.to_i }
                     .max
      (highest || 0) + 1
    end
  end
end
