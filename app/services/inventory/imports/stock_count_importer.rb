require "csv"

module Inventory
  module Imports
    # Imports counted quantities into a draft / in-progress stock count from a
    # CSV of "SKU, Counted Quantity" rows. Products are matched by SKU; the
    # quantities are written through Inventory::StockCountRecorder — the one
    # counting write path — so each imported row is a physical count with its
    # own count time and ledger baseline (decision D2), exactly like a quantity
    # typed on the counting screen. Existing lines for the same product are
    # updated. Rows with an unknown SKU or an unreadable quantity are skipped.
    class StockCountImporter
      REQUIRED_HEADERS = [ "sku", "counted quantity" ].freeze

      Result = Struct.new(:applied, :skipped, :header_error, keyword_init: true) do
        def ok?            = header_error.nil?
        def applied_count  = applied
        def skipped_count  = skipped.size
      end

      Skip = Struct.new(:row_number, :sku, :reason, keyword_init: true)

      def initialize(stock_count, csv_data, actor:)
        @count    = stock_count
        @business = stock_count.business
        @csv_data = csv_data
        @actor    = actor
      end

      # Set when the recorder refused the whole import (nothing written).
      attr_reader :error

      def call
        return Result.new(applied: 0, skipped: [], header_error: :not_draft) unless @count.editable_counts?

        table = parse
        return Result.new(applied: 0, skipped: [], header_error: :invalid_headers) unless headers_valid?(table)

        entries = []
        skipped = []

        table.each.with_index(2) do |row, line|
          sku     = row["sku"].to_s.strip
          counted = decimal(row["counted quantity"])

          if sku.blank? || counted.nil?
            skipped << Skip.new(row_number: line, sku: sku, reason: :invalid_row); next
          end
          product = @business.products.active.find_by("LOWER(sku) = ?", sku.downcase)
          if product.nil?
            skipped << Skip.new(row_number: line, sku: sku, reason: :unknown_sku); next
          end

          entries << { product_id: product.id, counted_quantity: counted.to_s("F") }
        end

        result = Inventory::StockCountRecorder.new(stock_count_id: @count.id, actor: @actor, entries: entries).call
        unless result.ok?
          @error = result.error
          return Result.new(applied: 0, skipped: skipped, header_error: :rejected)
        end
        applied = entries.size

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
        nil
      end
    end
  end
end
