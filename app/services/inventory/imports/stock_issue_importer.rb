require "csv"

module Inventory
  module Imports
    # Imports a stock issue from a CSV of "SKU, Quantity" rows, for a single
    # warehouse. Products are found by SKU; availability is validated; one issue
    # document is created for all valid lines. Returns a summary (issue + skipped
    # rows with reasons). If nothing is valid, no issue is created.
    class StockIssueImporter
      REQUIRED_HEADERS = [ "sku", "quantity" ].freeze

      Result = Struct.new(:issue, :skipped, :header_error, keyword_init: true) do
        def ok?           = header_error.nil?
        def issued_count  = issue&.items&.size.to_i
        def skipped_count = skipped.size
      end

      Skip = Struct.new(:row_number, :sku, :reason, keyword_init: true)

      def initialize(business, csv_data, warehouse:, user: nil)
        @business  = business
        @csv_data  = csv_data
        @warehouse = warehouse
        @user      = user
      end

      def call
        table = parse
        return Result.new(skipped: [], header_error: :invalid_headers) unless headers_valid?(table)

        skipped = []
        lines   = []

        table.each.with_index(2) do |row, line|
          sku = row["sku"].to_s.strip
          qty = decimal(row["quantity"])

          if sku.blank? || !qty.positive?
            skipped << Skip.new(row_number: line, sku: sku, reason: :invalid_row); next
          end
          product = @business.products.find_by("LOWER(sku) = ?", sku.downcase)
          if product.nil?
            skipped << Skip.new(row_number: line, sku: sku, reason: :unknown_sku); next
          end
          lines << { product: product, quantity: qty }
        end

        return Result.new(issue: nil, skipped: skipped) if lines.empty?

        issue = @business.stock_issues.build(warehouse: @warehouse, issued_on: Date.current, created_by: @user)
        lines.each { |l| issue.items.build(product: l[:product], quantity: l[:quantity]) }

        result = StockIssuePoster.new(issue).call
        unless result.ok?
          # The poster blocks the whole document on an availability shortfall;
          # surface that as a document-level skip so the summary explains it.
          issue.errors.full_messages.each { |m| skipped << Skip.new(row_number: nil, sku: nil, reason: m) }
          return Result.new(issue: nil, skipped: skipped)
        end

        Result.new(issue: issue, skipped: skipped)
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
