require "csv"

module Inventory
  module Imports
    # Imports a stock issue from a CSV of "SKU, Quantity" rows, for a single
    # warehouse. Exactly one StockIssue is created for the whole import and
    # used for its entire lifecycle: structurally-valid, in-stock rows are
    # attached to it as items immediately; everything else (blank/invalid
    # rows, unknown SKUs, or rows that collectively exceed on-hand stock) is
    # held in a `StockIssueImportBatch` so the user can fix it inline instead
    # of re-uploading the file — each resolved row appends its item to that
    # SAME issue. If nothing failed, the issue is posted right away; otherwise
    # it stays a draft until "Complete Import" posts it.
    class StockIssueImporter
      REQUIRED_HEADERS = [ "sku", "quantity" ].freeze

      # Column schema — single source of truth for the parser's headers, the
      # downloadable sample template, and the on-screen required/optional guide.
      # Header matching is case-insensitive (see #parse), so `header` casing is
      # for display only.
      Column = Struct.new(:header, :required, :example, keyword_init: true)
      COLUMNS = [
        Column.new(header: "SKU",      required: true, example: "WIDGET-001"),
        Column.new(header: "Quantity", required: true, example: "5")
      ].freeze

      # Header row + one example row, so users can fill in their own data.
      def self.sample_csv
        CSV.generate do |csv|
          csv << COLUMNS.map(&:header)
          csv << COLUMNS.map(&:example)
        end
      end

      Result = Struct.new(:issue, :batch, :header_error, keyword_init: true) do
        def ok? = header_error.nil?
      end

      Row = Struct.new(:row_number, :sku, :quantity, :product, :failure_reason, :available_hint, keyword_init: true)

      def initialize(business, csv_data, warehouse:, branch:, user: nil)
        @business  = business
        @csv_data  = csv_data
        @warehouse = warehouse
        @branch    = branch
        @user      = user
      end

      def call
        table = parse
        return Result.new(header_error: :invalid_headers) unless headers_valid?(table)

        rows = table.each.with_index(2).map { |row, line| build_row(row, line) }
        split_insufficient_stock!(rows)

        issue = @business.stock_issues.create!(
          warehouse: @warehouse, branch: @branch, issued_on: Date.current,
          created_by: @user, status: :draft
        )

        clean_rows, failed_rows = rows.partition { |r| r.failure_reason.nil? }
        clean_rows.each { |r| issue.items.create!(product: r.product, quantity: r.quantity) }

        if failed_rows.empty?
          result = StockIssuePoster.new(issue).call
          return Result.new(issue: result.issue, batch: nil) if result.ok?

          # The poster re-checked and blocked at posting time — e.g. a race
          # with stock consumed elsewhere between our pre-check and now.
          # Detach the just-created items (a row only owns an item once it's
          # actually resolved) and hold every row for resolution instead of
          # losing them.
          issue.items.destroy_all
          failed_rows = clean_rows.each { |r| r.failure_reason = :insufficient_stock }
        end

        batch = build_batch(issue, failed_rows)
        Result.new(issue: nil, batch: batch)
      end

      private

      def build_row(row, line)
        sku = row["sku"].to_s.strip
        qty = decimal(row["quantity"])

        if sku.blank? || !qty.positive?
          return Row.new(row_number: line, sku: sku, quantity: qty, failure_reason: :invalid_row)
        end

        product = @business.products.active.find_by("LOWER(sku) = ?", sku.downcase)
        return Row.new(row_number: line, sku: sku, quantity: qty, failure_reason: :unknown_sku) if product.nil?

        Row.new(row_number: line, sku: sku, quantity: qty, product: product)
      end

      # Mirrors StockIssuePoster#availability_ok? as a pre-filter: sums requested
      # quantity per product across the whole file and compares to on-hand. If a
      # product's rows collectively overshoot, none of them are safe to post
      # together, so all are held for the user to resolve individually. The
      # poster still re-checks authoritatively when the issue is finally posted.
      def split_insufficient_stock!(rows)
        rows.select { |r| r.product && r.failure_reason.nil? }
            .group_by(&:product)
            .each do |product, product_rows|
          available = product.stock_in(@warehouse)
          requested = product_rows.sum(&:quantity)
          next if requested <= available

          product_rows.each do |r|
            r.failure_reason = :insufficient_stock
            r.available_hint = available
          end
        end
      end

      def build_batch(issue, failed_rows)
        batch = StockIssueImportBatch.create!(
          business: @business, warehouse: @warehouse, branch: @branch,
          created_by: @user, stock_issue: issue, status: :draft
        )
        failed_rows.each do |r|
          batch.rows.create!(
            row_number: r.row_number, sku: r.sku, quantity: r.quantity,
            product: r.product, failure_reason: r.failure_reason,
            available_hint: r.available_hint, status: :pending
          )
        end
        batch
      end

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
