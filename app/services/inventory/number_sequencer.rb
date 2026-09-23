module Inventory
  # Generates per-business sequential document numbers (e.g. "GRN-000123",
  # "ISS-000123"). Race-safe via a transaction-level Postgres advisory lock
  # keyed by business + document kind, mirroring User#assign_employee_code:
  # concurrent inserts in the same business block until the first COMMITs, then
  # read the now-updated maximum. The per-business unique index on the number
  # column is the final database-level backstop.
  #
  # Must be called inside the transaction that persists the document so the lock
  # is held until COMMIT.
  class NumberSequencer
    # Distinct advisory-lock namespaces per document kind so receipts and issues
    # never serialize against each other.
    LOCK_NAMESPACES = {
      goods_receipt: 4101, stock_issue: 4102, stock_transfer: 4103,
      stock_adjustment: 4104, stock_count: 4105, purchase_request: 4106
    }.freeze

    CONFIG = {
      goods_receipt:    { model: "GoodsReceipt",    column: :receipt_number,    prefix: "GRN" },
      stock_issue:      { model: "StockIssue",      column: :issue_number,      prefix: "ISS" },
      stock_transfer:   { model: "StockTransfer",   column: :transfer_number,   prefix: "TRF" },
      stock_adjustment: { model: "StockAdjustment", column: :adjustment_number, prefix: "ADJ" },
      stock_count:      { model: "StockCount",      column: :count_number,      prefix: "SC" },
      purchase_request: { model: "PurchaseRequest", column: :request_number,    prefix: "PR" }
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

    # Highest existing numeric suffix for this business + 1. Non-matching legacy
    # numbers are ignored, so a hand-entered value never collides.
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
