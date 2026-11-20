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
    #   legacy            products whose product-level (legacy) low-stock
    #                     values are set. Those values belong to the
    #                     historical CENTRAL warehouse only; each is compared
    #                     with that warehouse's own row. Never with a branch.
    #   branch_rows       rows users configured explicitly in BRANCH
    #                     warehouses (kept Active by decision D1)
    #   stock_without_row pairs with on-hand ≠ 0 and no availability row
    #                     (Not Configured — new branch pairs stay so until a
    #                     person configures them)
    #   inactive_with_stock
    #   issues            suspicious records (see ISSUE_CODES)
    #
    # The historical central warehouse is the business's ONE warehouse of kind
    # "central". With none, or several, the report names the candidates and
    # does not guess (central_target nil): that choice belongs to a person.
    #
    # Scope: only the warehouses the viewer can reach (warehouse_ids nil =
    # every warehouse of the business). Aggregates are SQL; each list is
    # capped at LIST_LIMIT rows with its full count alongside.
    class AvailabilityReconciliation
      LIST_LIMIT = 200

      ISSUE_CODES = %w[
        untracked_with_settings active_row_in_inactive_warehouse active_row_for_archived_product
        row_for_parent_product row_in_unclassified_warehouse negative_on_hand
      ].freeze

      WarehouseRow = Struct.new(:warehouse, :active_rows, :inactive_rows, :unconfigured_with_stock,
                                :inactive_with_stock, keyword_init: true)
      # status: "matches" | "differs" | "no_central_row" | "central_row_inactive" | "no_central_target"
      LegacyRow = Struct.new(:product, :central_setting, :status, :transfer, keyword_init: true)
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
          scope = business.warehouses.includes(:branch).ordered
          scope = scope.where(id: @warehouse_ids) if @warehouse_ids
          scope.to_a
        end
      end

      # Every central-kind warehouse of the business (not only reachable ones:
      # the historical central warehouse is a business-wide fact).
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

      def legacy
        @legacy ||= begin
          # Also every product still relying on the legacy stock-wide alert
          # (no central row) without values to transfer (legacy_alert_only).
          products = business.products
                             .where("products.low_stock_level > 0 OR products.reorder_quantity > 0 OR " \
                                    "products.reorder_level > 0 OR products.receive_low_stock_notification = FALSE OR " \
                                    "(products.active AND products.track_inventory AND products.receive_low_stock_notification AND " \
                                    "NOT EXISTS (SELECT 1 FROM product_warehouse_settings a JOIN warehouses aw ON aw.id = a.warehouse_id " \
                                    "WHERE a.product_id = products.id AND aw.kind = 'central') AND " \
                                    "NOT EXISTS (SELECT 1 FROM products c WHERE c.parent_product_id = products.id))")
          total = products.count
          target = central_target
          visible = target && reachable?(target.id)
          # Products without a central row first, so the values still awaiting
          # transfer or review come before the products already configured.
          if visible
            products = products.order(Arel.sql(ActiveRecord::Base.sanitize_sql_array(
              [ "EXISTS (SELECT 1 FROM product_warehouse_settings s WHERE s.product_id = products.id AND s.warehouse_id = ?) ASC", target.id ]
            )))
          end
          page = products.order(:name, :id).limit(LIST_LIMIT).to_a
          # Only the central warehouse's rows are ever compared — and only when
          # the viewer can reach it.
          central_rows = visible ? ProductWarehouseSetting.where(warehouse_id: target.id, product_id: page.map(&:id)).index_by(&:product_id) : {}
          # The transfer outcome per product: the very classification the
          # transfer uses (Inventory::LegacyCentralSettingsBackfill).
          transfers = visible ? transfer_preview.rows.to_h { |r| [ r.product.id, r.category ] } : {}
          rows = page.map do |product|
            setting = central_rows[product.id]
            LegacyRow.new(product: product, central_setting: setting, status: legacy_status(product, setting, target),
                          transfer: transfers[product.id])
          end
          List.new(rows: rows, total: total)
        end
      end

      # The transfer's own preview (read-only): completed / pending / exceptions.
      def transfer_preview
        @transfer_preview ||= Inventory::LegacyCentralSettingsBackfill.new(business).dry_run
      end

      def transfer_visible? = central_target.present? && reachable?(central_target.id)

      # Products whose legacy total alert level (reorder_level) is set. Kept and
      # still used by LowStockQuery's total fallback while a product has no
      # availability rows; never mapped to a warehouse threshold (owner
      # decision, Nov 20 2026) until a separate retirement plan is approved.
      def legacy_total_alert_count
        @legacy_total_alert_count ||= business.products.where("products.reorder_level > 0").count
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
            if product.parent?
              found << Issue.new(code: "row_for_parent_product", product: product, warehouse: warehouse, setting: setting)
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

      def reachable?(warehouse_id) = @warehouse_ids.nil? || @warehouse_ids.include?(warehouse_id)

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

      def legacy_status(product, setting, target)
        return "no_central_target" if target.nil?
        return "no_central_row" if setting.nil?
        return "central_row_inactive" if setting.status_inactive?

        same = setting.low_stock_level.to_d == product.low_stock_level.to_d &&
               setting.reorder_quantity.to_d == product.reorder_quantity.to_d &&
               setting.receive_low_stock_notification == product.receive_low_stock_notification
        same ? "matches" : "differs"
      end
    end
  end
end
