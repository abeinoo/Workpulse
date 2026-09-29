module Inventory
  module Reports
    # Inventory Movement report: every ledger movement matching the filters,
    # newest first, with the running balance per (product, warehouse) after it.
    # Original AND reversal movements both appear (audit-faithful).
    #
    # Reads the same immutable ledger (InventoryMovement) as every stock figure
    # — nothing cached or duplicated. Only posting services write movements, so
    # drafts / submitted / approved / rejected / cancelled documents never
    # appear.
    #
    # Running balance: computed in SQL with a window function —
    #   SUM(±quantity) OVER (PARTITION BY product_id, warehouse_id
    #                        ORDER BY occurred_on, id)
    # over the product/warehouse's FULL history (only the partition-safe
    # warehouse/product filters apply inside the window). Date, type,
    # direction, source and document-number filters are applied OUTSIDE the
    # window, and pagination after that — so neither a filter nor a page
    # boundary can change a movement's historical balance. Only the requested
    # page is loaded (plus its product / warehouse / source preloads).
    class Movements
      PER_PAGE_OPTIONS = [ 25, 50, 100 ].freeze
      DEFAULT_PER_PAGE = 50
      EXPORT_BATCH     = 1_000

      # Source document → its table, alias and human document-number column.
      DOCUMENTS = {
        "GoodsReceipt"    => [ "goods_receipts",    "doc_gr", :receipt_number ],
        "StockIssue"      => [ "stock_issues",      "doc_si", :issue_number ],
        "StockTransfer"   => [ "stock_transfers",   "doc_st", :transfer_number ],
        "StockAdjustment" => [ "stock_adjustments", "doc_sa", :adjustment_number ],
        "LaundryBatch"    => [ "laundry_batches",   "doc_lb", :batch_number ]
      }.freeze
      DOCUMENT_NUMBER_COLUMNS = DOCUMENTS.transform_values(&:last).freeze
      DOCUMENT_JOINS = DOCUMENTS.map do |type, (table, as, _)|
        "LEFT JOIN #{table} #{as} ON inventory_movements.source_type = '#{type}' AND #{as}.id = inventory_movements.source_id"
      end.freeze
      DOCUMENT_NUMBER_SQL = "COALESCE(#{DOCUMENTS.values.map { |_, as, col| "#{as}.#{col}" }.join(', ')})".freeze

      SIGNED = "CASE WHEN inventory_movements.direction = 'in' " \
               "THEN inventory_movements.quantity ELSE -inventory_movements.quantity END".freeze
      BALANCE_WINDOW = "SUM(#{SIGNED}) OVER (PARTITION BY inventory_movements.product_id, " \
                       "inventory_movements.warehouse_id ORDER BY inventory_movements.occurred_on, " \
                       "inventory_movements.id)".freeze

      Row = Struct.new(
        :movement, :product, :warehouse, :direction, :reason,
        :quantity, :signed_quantity, :balance_after,
        :unit_cost, :total_value, :source, :document_number,
        keyword_init: true
      ) do
        def in_quantity    = direction == "in"  ? quantity : 0
        def out_quantity   = direction == "out" ? quantity : 0
        def balance_before = balance_after - signed_quantity
      end

      def initialize(business, warehouse_ids: nil, product_id: nil, from: nil, to: nil,
                     reason: nil, direction: nil, document_number: nil, source_type: nil, branch_id: nil)
        @business        = business
        @warehouse_ids   = warehouse_ids
        @product_id      = product_id
        @from            = self.class.parse_date(from)
        @to              = self.class.parse_date(to)
        @reason          = reason.presence_in(InventoryMovement.reasons.keys)
        @direction       = direction.presence_in(InventoryMovement.directions.keys)
        @document_number = document_number.to_s.strip.presence
        @source_type     = source_type.presence_in(DOCUMENTS.keys)
        @branch_id       = branch_id.presence&.to_i
      end

      def self.parse_date(value)
        return value if value.is_a?(Date)
        return nil if value.blank?

        Date.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def self.per_page_for(value)
        value.to_i.presence_in(PER_PAGE_OPTIONS) || DEFAULT_PER_PAGE
      end

      def self.document_number_for(source)
        column = source && DOCUMENT_NUMBER_COLUMNS[source.class.name]
        column && source.public_send(column)
      end

      def total_count
        @total_count ||= filtered.count
      end

      # One page of rows, newest first. `page` is clamped to the last page.
      def page(number, per_page)
        per    = self.class.per_page_for(per_page)
        number = number.to_i.clamp(1, total_pages(per))
        build_rows(ordered.includes(:product, :warehouse, :source).limit(per).offset((number - 1) * per))
      end

      def total_pages(per_page)
        [ (total_count.to_f / self.class.per_page_for(per_page)).ceil, 1 ].max
      end

      # Every matching row (newest first). For small result sets and the
      # dependent reports; exports use #each_row.
      def rows
        @rows ||= build_rows(ordered.includes(:product, :warehouse, :source))
      end

      # Streams every matching row in fixed-size pages so an export never
      # holds the whole ledger in memory. Same query, order and balances as
      # the screen.
      def each_row(batch_size: EXPORT_BATCH)
        return enum_for(:each_row, batch_size: batch_size) unless block_given?

        offset = 0
        loop do
          batch = ordered.includes(:product, :warehouse, :source).limit(batch_size).offset(offset).to_a
          break if batch.empty?

          build_rows(batch).each { |row| yield row }
          offset += batch_size
        end
      end

      private

      def build_rows(movements)
        movements.map do |movement|
          Row.new(
            movement:        movement,
            product:         movement.product,
            warehouse:       movement.warehouse,
            direction:       movement.direction,
            reason:          movement.reason,
            quantity:        movement.quantity,
            signed_quantity: movement.signed_quantity,
            balance_after:   movement.balance_after,
            unit_cost:       movement.unit_cost,
            total_value:     movement.quantity * movement.unit_cost,
            source:          movement.source,
            document_number: self.class.document_number_for(movement.source)
          )
        end
      end

      # Full-history ledger with the window balance, restricted only by the
      # partition-safe filters (warehouse, product).
      def ledger
        rel = InventoryMovement.where(business_id: @business.id)
        rel = rel.where(warehouse_id: @warehouse_ids) if @warehouse_ids
        rel = rel.where(product_id: @product_id)       if @product_id.present?
        rel.select("inventory_movements.*, #{BALANCE_WINDOW} AS balance_after")
      end

      # Row filters, applied outside the window.
      def filtered
        rel = InventoryMovement.from(ledger, :inventory_movements)
        rel = rel.where("inventory_movements.occurred_on >= ?", @from) if @from
        rel = rel.where("inventory_movements.occurred_on <= ?", @to)   if @to
        rel = rel.where(reason: @reason)                                if @reason
        rel = rel.where(direction: @direction)                          if @direction
        rel = rel.where(source_type: @source_type)                      if @source_type
        # Branch = the consuming branch, attributed exactly as ConsumptionLedger
        # does (a voided issue's reversal belongs to the issue's branch).
        if @branch_id
          rel = rel.joins(ConsumptionLedger::ISSUE_JOIN).joins(ConsumptionLedger::LAUNDRY_JOIN)
                   .where("#{ConsumptionLedger::BRANCH_SQL} = ?", @branch_id)
        end
        if @document_number
          rel = rel.joins(DOCUMENT_JOINS.join(" "))
                   .where("LOWER(#{DOCUMENT_NUMBER_SQL}) LIKE ?",
                          "%#{ActiveRecord::Base.sanitize_sql_like(@document_number.downcase)}%")
        end
        rel
      end

      def ordered
        filtered.select("inventory_movements.*").order("inventory_movements.occurred_on DESC, inventory_movements.id DESC")
      end
    end
  end
end
