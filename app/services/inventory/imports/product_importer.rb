require "csv"

module Inventory
  module Imports
    # Imports products from a CSV. Columns (header row, case-insensitive):
    #   Product Name, SKU, Barcode, Brand, Category, Initial Cost,
    #   Current Stock, Low Stock Level, Reorder Quantity
    #
    # Validates duplicate SKU / barcode (against the database AND within the file)
    # before importing — offending rows are skipped and reported. Brands and
    # categories are matched by name (created on demand). If a target warehouse is
    # given, any positive "Current Stock" is posted as ONE opening-balance
    # adjustment valued at each row's Initial Cost.
    class ProductImporter
      REQUIRED_HEADERS = [ "product name", "sku" ].freeze

      # Column schema — single source of truth for the parser's headers, the
      # downloadable sample template, and the on-screen required/optional guide.
      # Header matching is case-insensitive (see #parse), so `header` casing is
      # for display only.
      Column = Struct.new(:header, :required, :example, keyword_init: true)
      COLUMNS = [
        Column.new(header: "Product Name",     required: true,  example: "Sample Widget"),
        Column.new(header: "SKU",              required: true,  example: "WIDGET-001"),
        Column.new(header: "Barcode",          required: false, example: "6291000000017"),
        Column.new(header: "Brand",            required: false, example: "Acme"),
        Column.new(header: "Category",         required: false, example: "Hardware"),
        Column.new(header: "Initial Cost",     required: false, example: "12.50"),
        Column.new(header: "Current Stock",    required: false, example: "100"),
        Column.new(header: "Low Stock Level",  required: false, example: "10"),
        Column.new(header: "Reorder Quantity", required: false, example: "50")
      ].freeze

      # Header row + one example row, so users can fill in their own data.
      def self.sample_csv
        CSV.generate do |csv|
          csv << COLUMNS.map(&:header)
          csv << COLUMNS.map(&:example)
        end
      end

      Result = Struct.new(:created, :skipped, :opening_adjustment, :header_error, keyword_init: true) do
        def ok?            = header_error.nil?
        def created_count  = created.size
        def skipped_count  = skipped.size
      end

      Skip = Struct.new(:row_number, :sku, :reason, keyword_init: true)

      def initialize(business, csv_data, warehouse: nil, user: nil)
        @business  = business
        @csv_data  = csv_data
        @warehouse = warehouse
        @user      = user
      end

      def call
        table = parse
        return Result.new(created: [], skipped: [], header_error: :invalid_headers) unless headers_valid?(table)

        created  = []
        skipped  = []
        openings = []
        seen_skus     = {}
        seen_barcodes = {}

        ActiveRecord::Base.transaction do
          table.each.with_index(2) do |row, line| # header is line 1
            sku     = row["sku"].to_s.strip
            barcode = row["barcode"].to_s.strip.presence
            name    = row["product name"].to_s.strip

            if name.blank? || sku.blank?
              skipped << Skip.new(row_number: line, sku: sku, reason: :missing_required); next
            end
            if seen_skus[sku.downcase] || @business.products.where("LOWER(sku) = ?", sku.downcase).exists?
              skipped << Skip.new(row_number: line, sku: sku, reason: :duplicate_sku); next
            end
            if barcode && (seen_barcodes[barcode.downcase] || @business.products.where("LOWER(barcode) = ?", barcode.downcase).exists?)
              skipped << Skip.new(row_number: line, sku: sku, reason: :duplicate_barcode); next
            end

            initial_cost = decimal(row["initial cost"])
            product = @business.products.build(
              name:               name,
              sku:                sku,
              barcode:            barcode,
              brand:              find_or_create(@business.brands, row["brand"]),
              product_category:   find_or_create(@business.product_categories, row["category"]),
              initial_cost_price: initial_cost,
              average_cost_price: initial_cost,
              low_stock_level:    decimal(row["low stock level"]),
              reorder_quantity:   decimal(row["reorder quantity"])
            )

            unless product.save
              skipped << Skip.new(row_number: line, sku: sku, reason: :invalid); next
            end

            seen_skus[sku.downcase] = true
            seen_barcodes[barcode.downcase] = true if barcode
            created << product

            current_stock = decimal(row["current stock"])
            openings << { product: product, quantity: current_stock, unit_cost: initial_cost } if @warehouse && current_stock.positive?
          end

          adjustment = post_opening_balances(openings)
          return Result.new(created: created, skipped: skipped, opening_adjustment: adjustment)
        end
      end

      private

      def parse
        CSV.parse(@csv_data, headers: true, header_converters: ->(h) { h.to_s.strip.downcase })
      end

      def headers_valid?(table)
        (REQUIRED_HEADERS - table.headers.compact).empty?
      end

      def find_or_create(relation, name)
        name = name.to_s.strip
        return nil if name.blank?
        relation.find_or_create_by!(name: name)
      end

      def decimal(value)
        BigDecimal(value.to_s.strip)
      rescue ArgumentError, TypeError
        0
      end

      def post_opening_balances(openings)
        return nil if openings.empty?

        adjustment = @business.stock_adjustments.build(
          warehouse: @warehouse, adjusted_on: Date.current, reason: :opening_balance,
          created_by: @user, notes: "Opening balances from product import"
        )
        openings.each do |o|
          adjustment.items.build(product: o[:product], quantity_difference: o[:quantity], unit_cost: o[:unit_cost])
        end
        result = AdjustmentPoster.new(adjustment).call
        raise ActiveRecord::Rollback unless result.ok?
        adjustment
      end
    end
  end
end
