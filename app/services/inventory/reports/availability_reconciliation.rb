module Inventory
  module Reports
    # Product availability per warehouse — Phase 2 reconciliation report.
    # READ-ONLY: it creates no availability row, changes no status, rewrites
    # no movement and applies nothing. It shows a human reviewer what a future
    # reconciliation (Phase 3, separately approved) would have to decide:
    #
    #   warehouses        per reachable warehouse: Active / Inactive rows,
    #                     Not Configured pairs holding stock, Inactive pairs
    #                     holding stock
    #   branch_rows       rows users configured explicitly in BRANCH
    #                     warehouses (kept Active by decision D1)
    #   stock_without_row pairs with on-hand ≠ 0 and no availability row
    #                     (Not Configured — new branch pairs stay so until a
    #                     person configures them)
    #   inactive_with_stock
    #   issues            suspicious records (see ISSUE_CODES)
    #
    # The central warehouse is the business's ONE warehouse of kind "central".
    # With none, or several, the report names the candidates and does not
    # guess (central_target nil): that choice belongs to a person.
    #
    # Scope: only the warehouses the viewer can reach (warehouse_ids nil =
    # every warehouse of the business). Aggregates are SQL; each list is
    # capped at LIST_LIMIT rows with its full count alongside.
    class AvailabilityReconciliation
      LIST_LIMIT = 200

      ISSUE_CODES = %w[
        untracked_with_settings active_row_in_inactive_warehouse active_row_for_archived_product
        row_in_unclassified_warehouse negative_on_hand
      ].freeze

      WarehouseRow = Struct.new(:warehouse, :active_rows, :inactive_rows, :unconfigured_with_stock,
                                :inactive_with_stock, keyword_init: true)
      PairRow   = Struct.new(:product, :warehouse, :setting, :on_hand, keyword_init: true)
      Issue     = Struct.new(:code, :product, :warehouse, :setting, :detail, keyword_init: true)
      List      = Struct.new(:rows, :total, keyword_init: true) do
        def truncated? = total > rows.size
      end

      attr_reader :business

      def initialize(business, warehouse_ids: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
      end

      def warehouses
        @warehouses ||= begin
          scope = business.warehouses.operational.includes(:branch).ordered
          scope = scope.where(id: @warehouse_ids) if @warehouse_ids
          scope.to_a
        end
      end

      # Every central-kind warehouse of the business (not only reachable ones:
      # the central warehouse is a business-wide fact).
      def central_candidates
        @central_candidates ||= business.warehouses.kind_central.ordered.to_a
      end

      def central_target = central_candidates.one? ? central_candidates.first : nil

      def unclassified_warehouses = warehouses.select { |w| w.kind.nil? }

      def warehouse_rows
        @warehouse_rows ||= begin
          counts = settings_scope.group(:warehouse_id, :status).count
          unconfigured = stock_without_row_pairs.map { |_product_id, warehouse_id, _qty| warehouse_id }.tally
          inactive_stock = inactive_with_stock_pairs.map { |setting, _| setting.warehouse_id }.tally
          warehouses.map do |w|
            WarehouseRow.new(warehouse: w, active_rows: counts[[ w.id, "active" ]].to_i,
                             inactive_rows: counts[[ w.id, "inactive" ]].to_i,
                             unconfigured_with_stock: unconfigured[w.id].to_i,
                             inactive_with_stock: inactive_stock[w.id].to_i)
          end
        end
      end

      def branch_rows
        @branch_rows ||= begin
          scope = settings_scope.joins(:warehouse).where(warehouses: { kind: "branch" })
          List.new(rows: scope.includes(:product, :warehouse).order("warehouses.name", :product_id).limit(LIST_LIMIT).to_a,
                   total: scope.count)
        end
      end

      def stock_without_row
        @stock_without_row ||= begin
          pairs = stock_without_row_pairs
          shown = pairs.first(LIST_LIMIT)
          products = business.products.where(id: shown.map(&:first)).index_by(&:id)
          by_id = warehouses.index_by(&:id)
          rows = shown.map do |product_id, warehouse_id, on_hand|
            PairRow.new(product: products[product_id], warehouse: by_id[warehouse_id], on_hand: on_hand.to_d)
          end
          List.new(rows: rows, total: pairs.size)
        end
      end

      def inactive_with_stock
        @inactive_with_stock ||= begin
          pairs = inactive_with_stock_pairs
          rows = pairs.first(LIST_LIMIT).map do |setting, on_hand|
            PairRow.new(product: setting.product, warehouse: setting.warehouse, setting: setting, on_hand: on_hand.to_d)
          end
          List.new(rows: rows, total: pairs.size)
        end
      end

      def issues
        @issues ||= begin
          found = []
          settings_scope.includes(:product, :warehouse).find_each do |setting|
            product   = setting.product
            warehouse = setting.warehouse
            if !product.track_inventory? && (setting.low_stock_level.to_d.positive? || setting.reorder_quantity.to_d.positive?)
              found << Issue.new(code: "untracked_with_settings", product: product, warehouse: warehouse, setting: setting)
            end
            if setting.status_active? && !warehouse.active?
              found << Issue.new(code: "active_row_in_inactive_warehouse", product: product, warehouse: warehouse, setting: setting)
            end
            if setting.status_active? && !product.active?
              found << Issue.new(code: "active_row_for_archived_product", product: product, warehouse: warehouse, setting: setting)
            end
            if warehouse.kind.nil?
              found << Issue.new(code: "row_in_unclassified_warehouse", product: product, warehouse: warehouse, setting: setting)
            end
          end
          negative = levels.select { |_, qty| qty.to_d.negative? }
          products = business.products.where(id: negative.keys.map(&:first)).index_by(&:id)
          by_id = warehouses.index_by(&:id)
          negative.each do |(product_id, warehouse_id), qty|
            found << Issue.new(code: "negative_on_hand", product: products[product_id], warehouse: by_id[warehouse_id],
                               detail: qty.to_d)
          end
          @issue_counts = found.map(&:code).tally
          List.new(rows: found.first(LIST_LIMIT), total: found.size)
        end
      end

      # { code => count } over every issue found (not only the listed rows).
      def issue_counts
        issues
        @issue_counts
      end

      private

      def settings_scope
        scope = ProductWarehouseSetting.where(business_id: business.id)
        scope = scope.where(warehouse_id: @warehouse_ids) if @warehouse_ids
        scope
      end

      # { [product_id, warehouse_id] => on_hand } over the reachable warehouses.
      def levels
        @levels ||= begin
          scope = InventoryMovement.where(business_id: business.id)
          scope = scope.where(warehouse_id: @warehouse_ids) if @warehouse_ids
          scope.group(:product_id, :warehouse_id).sum(Arel.sql(StockLevels::SIGNED))
        end
      end

      def configured_pairs
        @configured_pairs ||= settings_scope.pluck(:product_id, :warehouse_id).to_set
      end

      # [[product_id, warehouse_id, on_hand]] — stock and no row, by warehouse
      # then product. Sales branch warehouses are left out: there a product
      # with no row is Included by default (Warehouse#availability_included_by_default?).
      def stock_without_row_pairs
        included = warehouses.select(&:availability_included_by_default?).to_set(&:id)
        @stock_without_row_pairs ||= levels.reject { |pair, qty| qty.to_d.zero? || configured_pairs.include?(pair) || included.include?(pair.last) }
                                           .map { |(product_id, warehouse_id), qty| [ product_id, warehouse_id, qty ] }
                                           .sort_by { |product_id, warehouse_id, _| [ warehouse_id, product_id ] }
      end

      # [[setting, on_hand]] — Inactive rows whose pair still holds stock.
      def inactive_with_stock_pairs
        @inactive_with_stock_pairs ||= settings_scope.status_inactive.includes(:product, :warehouse).order(:warehouse_id, :product_id)
                                                     .filter_map do |setting|
          qty = levels[[ setting.product_id, setting.warehouse_id ]].to_d
          [ setting, qty ] unless qty.zero?
        end
      end
    end
  end
end
