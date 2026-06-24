require "csv"

module Inventory
  module Imports
    # Imports counted quantities into an existing DRAFT stock count from a CSV of
    # "SKU, Counted Quantity" rows. Products are matched by SKU; the system
    # quantity is snapshotted from live stock in the count's warehouse and the
    # variance computed. Existing lines for the same product are updated.
    class StockCountImporter
      REQUIRED_HEADERS = [ "sku", "counted quantity" ].freeze

      Result = Struct.new(:applied, :skipped, :header_error, keyword_init: true) do
        def ok?            = header_error.nil?
        def applied_count  = applied
        def skipped_count  = skipped.size
      end

      Skip = Struct.new(:row_number, :sku, :reason, keyword_init: true)

      def initialize(stock_count, csv_data)
        @count    = stock_count
        @business = stock_count.business
        @csv_data = csv_data
      end

      def call
        return Result.new(applied: 0, skipped: [], header_error: :not_draft) unless @count.editable_counts?

        table = parse
        return Result.new(applied: 0, skipped: [], header_error: :invalid_headers) unless headers_valid?(table)

        applied = 0
        skipped = []

        ActiveRecord::Base.transaction do
          table.each.with_index(2) do |row, line|
            sku     = row["sku"].to_s.strip
            counted = decimal(row["counted quantity"])

            if sku.blank?
              skipped << Skip.new(row_number: line, sku: sku, reason: :invalid_row); next
            end
            product = @business.products.active.find_by("LOWER(sku) = ?", sku.downcase)
            if product.nil?
              skipped << Skip.new(row_number: line, sku: sku, reason: :unknown_sku); next
            end

            item = @count.items.find_or_initialize_by(product: product)
            item.system_quantity  = product.stock_in(@count.warehouse)
            item.counted_quantity = counted
            item.save!
            applied += 1
          end
        end

        Result.new(applied: applied, skipped: skipped)
      end

      private

      def parse
        CSV.parse(@csv_data, headers: true, header_converters: ->(h) { h.to_s.strip.downcase })
      end

      def headers_valid?(table)
        (REQUIRED_HEADERS - table.headers.compact).empty?
      end

      def decimal(value)
        BigDecimal(value.to_s.strip)
      rescue ArgumentError, TypeError
        0
      end
    end
  end
end
