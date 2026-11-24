require "csv"

module Inventory
  module Imports
    # Imports products from a CSV. Columns (header row, case-insensitive):
    #   Product Name, SKU, Barcode, Brand, Category, Measure, Initial Cost,
    #   Current Stock, Low Stock Level, Reorder Quantity
    #
    # "Measure" (optional; older files without it still import): the code
    # (ml, l, fl_oz, g, kg, gal, oz, lb, cm, ft, in, pieces), its English or
    # Arabic short label or full name, case-insensitive. Blank = a whole
    # product (pieces); an unknown value skips the row (:invalid_measure).
    #
    # Each row creates one product.
    #
    # Validates duplicate SKU / barcode (against the database AND within the file)
    # before importing — offending rows are skipped and reported. Brands and
    # categories are matched by name (created on demand). If a target warehouse is
    # given, any positive "Current Stock" is posted as ONE opening-balance
    # adjustment valued at each row's Initial Cost.
    #
    # "Low Stock Level" / "Reorder Quantity" are the CENTRAL warehouse's settings
    # for the new product (never the deprecated product-level columns): a row
    # with either cell filled gets one Active central availability row with the
    # exact values (zeros kept; a blank cell = 0) through
    # Inventory::ProductAvailabilityManager#add_many (authorized for the
    # importing user, audited, source "product_import"). Both cells blank: no
    # row. The central warehouse is the business's ONE active warehouse of kind
    # "central" (never an id); none / several, a user who may not manage it, a
    # conflicting existing row or a failed audit entry refuse the WHOLE import
    # (settings_error) — nothing is written. A non-numeric or negative value
    # skips that row (:invalid_stock_settings).
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
        Column.new(header: "Measure",          required: false, example: "ml"),
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

      ParseError = Struct.new(:line_number, :raw_line, :message, keyword_init: true)

      # opening_errors: the opening-balance adjustment was refused (e.g. a
      # missing unit cost, or a product Inactive in the target warehouse) —
      # the WHOLE import was rolled back; the messages name product and reason.
      # settings_error: the central warehouse settings could not be written
      # (:no_central_warehouse, :ambiguous_central_warehouse, :not_authorized,
      # :settings_conflict, :audit_failed, ...) — nothing was imported.
      Result = Struct.new(:created, :skipped, :opening_adjustment, :header_error, :parse_error, :opening_errors,
                          :settings_error, :central_warehouse, keyword_init: true) do
        def ok?            = header_error.nil? && opening_errors.blank? && settings_error.nil?
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
        if table.is_a?(ParseError)
          return Result.new(created: [], skipped: [], header_error: :malformed_csv, parse_error: table)
        end
        return Result.new(created: [], skipped: [], header_error: :invalid_headers) unless headers_valid?(table)

        # The central warehouse is resolved before anything is written.
        central = nil
        if table.any? { |row| settings_given?(row) }
          candidates = @business.warehouses.kind_central.where(status: "active").order(:id).limit(2).to_a
          unless candidates.one?
            error = candidates.empty? ? :no_central_warehouse : :ambiguous_central_warehouse
            return Result.new(created: [], skipped: [], settings_error: error)
          end
          central = candidates.first
        end
        settings = [] # [{ product_id:, low_stock_level:, reorder_quantity: }] for the central warehouse

        created  = []
        skipped  = []
        openings = []
        seen_skus     = {}
        seen_barcodes = {}

        opening_errors = nil
        settings_error = nil
        ActiveRecord::Base.transaction do
          table.each.with_index(2) do |row, line| # header is line 1
            sku     = row["sku"].to_s.strip
            barcode = ProductBarcode.normalize(row["barcode"])
            name    = row["product name"].to_s.strip

            if name.blank? || sku.blank?
              skipped << Skip.new(row_number: line, sku: sku, reason: :missing_required); next
            end
            if seen_skus[sku.downcase] || @business.products.where("LOWER(sku) = ?", sku.downcase).exists?
              skipped << Skip.new(row_number: line, sku: sku, reason: :duplicate_sku); next
            end
            if barcode && (seen_barcodes[ProductBarcode.comparison_key(barcode)] ||
                           ProductBarcode.where(business_id: @business.id).matching(barcode).exists?)
              skipped << Skip.new(row_number: line, sku: sku, reason: :duplicate_barcode); next
            end

            measure = measure_for(row["measure"])
            if measure.nil?
              skipped << Skip.new(row_number: line, sku: sku, reason: :invalid_measure); next
            end

            stock_settings = stock_settings_for(row)
            if stock_settings == :invalid
              skipped << Skip.new(row_number: line, sku: sku, reason: :invalid_stock_settings); next
            end

            initial_cost = decimal(row["initial cost"])
            product = @business.products.build(
              name:               name,
              sku:                sku,
              barcode:            barcode,
              brand:              find_or_create(@business.brands, row["brand"]),
              product_category:   find_or_create(@business.product_categories, row["category"]),
              unit_of_measure:    measure,
              initial_cost_price: initial_cost,
              average_cost_price: initial_cost
            )

            unless product.save
              skipped << Skip.new(row_number: line, sku: sku, reason: :invalid); next
            end

            seen_skus[sku.downcase] = true
            seen_barcodes[ProductBarcode.comparison_key(barcode)] = true if barcode
            created << product
            settings << stock_settings.merge(product_id: product.id) if stock_settings

            current_stock = decimal(row["current stock"])
            openings << { product: product, quantity: current_stock, unit_cost: initial_cost } if @warehouse && current_stock.positive?
          end

          if settings.any?
            result = ProductAvailabilityManager.new(actor: @user).add_many(warehouse_id: central.id, items: settings, source: "product_import")
            unless result.ok? && result.skipped.empty?
              settings_error = result.ok? ? :settings_conflict : result.error
              raise ActiveRecord::Rollback
            end
          end

          adjustment, refused = post_opening_balances(openings)
          if refused
            opening_errors = refused.errors.full_messages.presence || [ I18n.t("inventory.imports.opening_balance_unknown_error") ]
            raise ActiveRecord::Rollback
          end
          return Result.new(created: created, skipped: skipped, opening_adjustment: adjustment, central_warehouse: central)
        end

        return Result.new(created: [], skipped: [], settings_error: settings_error, central_warehouse: central) if settings_error

        Result.new(created: [], skipped: [], opening_errors: opening_errors)
      end

      private

      def parse
        data = @csv_data.dup.force_encoding("UTF-8")
        data = data.delete_prefix("\xEF\xBB\xBF")  # strip Excel UTF-8 BOM
        CSV.parse(data, headers: true,
                        header_converters: ->(h) { h.to_s.strip.downcase },
                        liberal_parsing: true)
      rescue CSV::MalformedCSVError => e
        ParseError.new(
          line_number: e.line_number,
          raw_line:    @csv_data.lines[e.line_number - 1].to_s.strip,
          message:     e.message
        )
      end

      # A Measure cell → its code (blank = pieces), or nil when unknown.
      def measure_for(value)
        text = value.to_s.strip.downcase
        return Product::DEFAULT_UNIT_OF_MEASURE if text.empty?

        self.class.measure_aliases[text]
      end

      # { "ml" => "ml", "millilitres (ml)" => "ml", "مل" => "ml", "piece" => "pieces", … }
      def self.measure_aliases
        @measure_aliases ||= Product::UNITS_OF_MEASURE.each_with_object({ "piece" => "pieces", "pcs" => "pieces" }) do |code, map|
          map[code] = code
          map[code.tr("_", " ")] = code
          %i[en ar].each do |locale|
            %w[name short].each { |key| map[I18n.t("inventory.measures.#{code}.#{key}", locale: locale).downcase] = code }
          end
        end
      end

      def headers_valid?(table)
        (REQUIRED_HEADERS - table.headers.compact).empty?
      end

      def find_or_create(relation, name)
        name = name.to_s.strip
        return nil if name.blank?
        relation.find_or_create_by!(name: name)
      end

      SETTINGS_COLUMNS = [ "low stock level", "reorder quantity" ].freeze

      def settings_given?(row) = SETTINGS_COLUMNS.any? { |column| row[column].to_s.strip.present? }

      # nil (both cells blank: no central row), :invalid, or the exact values
      # (a blank cell next to a filled one = 0).
      def stock_settings_for(row)
        return nil unless settings_given?(row)

        low, reorder = SETTINGS_COLUMNS.map do |column|
          text = row[column].to_s.strip
          next 0.to_d if text.empty?

          value = BigDecimal(text, exception: false)
          return :invalid if value.nil? || value.negative?

          value
        end
        { low_stock_level: low, reorder_quantity: reorder }
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
        result = AdjustmentPoster.new(adjustment, actor: @user).call
        result.ok? ? [ adjustment, nil ] : [ nil, adjustment ]
      end
    end
  end
end
