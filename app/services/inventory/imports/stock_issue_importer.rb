require "csv"

module Inventory
  module Imports
    # Imports a stock issue from "SKU, Quantity" rows, for a single warehouse.
    # Rows arrive already normalized by CsvColumnMapper (the user maps their
    # CSV's own columns onto COLUMNS), so this class never reads raw headers:
    #
    #   [{ row_number: 2, "sku" => "UYN1", "quantity" => "2" }, ...]
    # Exactly one StockIssue is created for the whole import and
    # used for its entire lifecycle: structurally-valid, in-stock rows are
    # attached to it as items immediately; everything else (blank/invalid rows, unknown SKUs, or rows that
    # collectively exceed on-hand stock) is held in a `StockIssueImportBatch`
    # so the user can fix it inline instead of re-uploading the file — each
    # resolved row appends its item to that SAME issue.
    #
    # An import NEVER deducts stock. If nothing failed, the issue is submitted
    # for approval right away (draft -> pending_approval, via
    # Inventory::StockIssueSubmission); otherwise it stays a draft until
    # "Complete Import" submits it. From there it follows the same workflow as
    # a manual issue: approve, then "Confirm Issue" posts the stock movements.
    class StockIssueImporter
      include AuditLoggable

      # Field schema — single source of truth for the column-mapping step
      # (key + auto-match synonyms), the downloadable sample template, and the
      # on-screen required/optional guide. `synonyms` are in priority order;
      # `fallback_synonyms` are only suggested when nothing better matches.
      Column = Struct.new(:key, :header, :required, :example, :synonyms, :fallback_synonyms, keyword_init: true)
      COLUMNS = [
        Column.new(key: "sku", header: "SKU", required: true, example: "WIDGET-001",
                   synonyms: [ "SKU", "Product SKU", "Item SKU", "Item Code", "Product Code", "Code",
                               "رمز المنتج", "كود المنتج", "كود الصنف", "رمز الصنف", "الرمز", "الكود", "كود" ],
                   fallback_synonyms: [ "Barcode", "الباركود", "باركود" ]),
        Column.new(key: "quantity", header: "Quantity", required: true, example: "5",
                   synonyms: [ "Quantity", "Qty", "Qty ordered", "Quantity ordered", "Ordered qty",
                               "Requested Quantity", "Qty requested", "Issue quantity", "Qty to issue",
                               "الكمية", "كمية", "الكمية المطلوبة", "الكمية المصروفة" ])
      ].freeze

      # Header row + one example row, so users can fill in their own data.
      def self.sample_csv
        CSV.generate do |csv|
          csv << COLUMNS.map(&:header)
          csv << COLUMNS.map(&:example)
        end
      end

      # Excel version of the same template. SKU is a text cell so codes with
      # leading zeros (e.g. 00123) survive a round-trip through Excel.
      def self.sample_xlsx
        package = Axlsx::Package.new
        package.workbook.add_worksheet(name: "Stock Issue") do |sheet|
          sheet.add_row COLUMNS.map(&:header)
          sheet.add_row COLUMNS.map(&:example), types: [ :string, :integer ]
        end
        package.to_stream.read
      end

      Result = Struct.new(:issue, :batch, keyword_init: true) do
        def ok? = issue.present? || batch.present?
      end

      # failure_reason is what the resolution batch persists; `detail` refines
      # :invalid_row for display (:missing_sku, :invalid_quantity,
      # :non_positive_quantity).
      Row = Struct.new(:row_number, :sku, :quantity, :product, :failure_reason, :detail, :available_hint,
                       keyword_init: true) do
        def valid? = failure_reason.nil?
      end

      # `notes` is the document-level note for the whole issue (the import
      # form's "Stock Issue Notes" field) — saved on StockIssue#notes, never
      # on individual lines. Optional.
      def initialize(business, rows, warehouse:, branch:, user: nil, notes: nil)
        @business  = business
        @rows      = rows
        @warehouse = warehouse
        @branch    = branch
        @user      = user
        @notes     = notes.to_s.strip.presence
      end

      # Side-effect-free dry run: exactly the rows #call would build, with the
      # same failure reasons — used by the preview step.
      def preview
        build_rows
      end

      # All-or-nothing: the issue, its items, and its submission (or its
      # resolution batch) are written in one transaction. The importing user
      # is required — they are the issue's creator and submitter, which also
      # means the approval step's self-approval rule applies to them.
      def call
        raise ArgumentError, "an importing user is required" if @user.nil?

        rows = build_rows
        clean_rows, failed_rows = rows.partition(&:valid?)

        ActiveRecord::Base.transaction do
          issue = @business.stock_issues.create!(
            warehouse: @warehouse, branch: @branch, issued_on: Date.current,
            created_by: @user, status: :draft, notes: @notes
          )
          clean_rows.each { |r| issue.items.create!(product: r.product, quantity: r.quantity) }
          log_audit(actor: @user, auditable: issue, action: "create", metadata: { source: "import" })

          if failed_rows.empty?
            submit_for_approval!(issue)
            Result.new(issue: issue.reload, batch: nil)
          else
            Result.new(issue: nil, batch: build_batch(issue, failed_rows))
          end
        end
      end

      private

      def build_rows
        products = products_by_sku
        rows = @rows.map { |row| build_row(row, products) }
        split_insufficient_stock!(rows)
        rows
      end

      def build_row(row, products)
        line = row[:row_number]
        sku  = row["sku"].to_s.strip
        qty  = decimal(row["quantity"])

        detail = if sku.blank? then :missing_sku
        elsif qty.nil? then :invalid_quantity
        elsif !qty.positive? then :non_positive_quantity
        end
        if detail
          return Row.new(row_number: line, sku: sku, quantity: qty || 0, failure_reason: :invalid_row, detail: detail)
        end

        product = products[sku.downcase]
        return Row.new(row_number: line, sku: sku, quantity: qty, failure_reason: :unknown_sku) if product.nil?

        Row.new(row_number: line, sku: sku, quantity: qty, product: product)
      end

      # One query for every SKU in the file (case-insensitive, active only).
      def products_by_sku
        skus = @rows.map { |r| r["sku"].to_s.strip.downcase }.reject(&:empty?).uniq
        return {} if skus.empty?

        @business.products.active.where("LOWER(sku) IN (?)", skus).index_by { |p| p.sku.downcase }
      end

      # Mirrors StockIssuePoster#availability_ok? as a pre-filter: sums requested
      # quantity per product across the whole file and compares to on-hand. If a
      # product's rows collectively overshoot, none of them are safe to post
      # together, so all are held for the user to resolve individually. The
      # poster still re-checks authoritatively when the approved issue is
      # finally confirmed.
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

      # Enters the standard approval workflow — never posts stock. A failed
      # submission rolls back the whole import.
      def submit_for_approval!(issue)
        result = StockIssueSubmission.new(stock_issue_id: issue.id, actor: @user).call
        raise ActiveRecord::RecordInvalid, result.issue unless result.ok?
      end

      # nil when unparsable, so "abc" (invalid) is told apart from "0".
      def decimal(value)
        BigDecimal(value.to_s.strip)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
