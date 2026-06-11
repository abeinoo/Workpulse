require "csv"

module Inventory
  # CSV export of a stock-count session: one row per product with the system and
  # counted quantities and the variance. Uncounted rows export a blank counted
  # quantity and difference (mirroring the on-screen state).
  class StockCountCsv
    HEADERS = [ "Product", "Barcode", "SKU", "System Quantity", "Counted Quantity", "Difference" ].freeze

    def initialize(stock_count)
      @count = stock_count
    end

    def filename
      "#{@count.count_number}.csv"
    end

    def to_csv
      CSV.generate do |csv|
        csv << HEADERS
        @count.items.includes(:product).each do |item|
          csv << [
            item.product.name,
            item.product.barcode,
            item.product.sku,
            fmt(item.system_quantity),
            item.counted? ? fmt(item.counted_quantity) : nil,
            item.counted? ? fmt(item.difference) : nil
          ]
        end
      end
    end

    private

    # Whole numbers without a trailing ".0"; fractional counts keep their decimals.
    def fmt(value)
      d = value.to_d
      d.frac.zero? ? d.to_i.to_s : d.to_s("F")
    end
  end
end
