module Inventory
  # Computes low-stock alerts, evaluated PER WAREHOUSE.
  #
  # For each product:
  #   - Every Active per-warehouse row (ProductWarehouseSetting) with a
  #     threshold above 0 is checked independently against its own
  #     low_stock_level — so a branch warehouse at zero stock alerts even when
  #     another warehouse is well stocked. Threshold 0 = no alert there.
  #   - The legacy total-stock alert (total stock <= products.reorder_level;
  #     level 0 = out of stock) applies until the product's CENTRAL warehouse
  #     has its own row — i.e. until its legacy values were transferred there
  #     (Inventory::LegacyCentralSettingsBackfill) or set there by a user.
  #     Branch rows do not end it. It is reported only when none of the
  #     product's warehouse alerts fired (never two alerts for one product
  #     from the two systems).
  #
  # Two aggregate queries only (movement levels grouped by product+warehouse,
  # plus the products with their settings) — no per-row N+1.
  class LowStockQuery
    SIGNED = "CASE WHEN direction = 'in' THEN quantity ELSE -quantity END".freeze

    Alert = Struct.new(
      :product, :warehouse_id, :warehouse_name,
      :on_hand, :low_stock_level, :reorder_quantity, :notifiable,
      keyword_init: true
    ) do
      # nil warehouse_id means the alert is on total (all-warehouse) stock.
      def total? = warehouse_id.nil?

      # Detected alerts feed reports, KPIs, pickers and pages; only notifiable
      # ones belong on notification (dashboard) surfaces. A per-warehouse alert
      # follows that pair's receive_low_stock_notification; the legacy total
      # alert is already limited to products with the product-level flag on.
      def notifiable? = notifiable != false
    end

    # warehouse_ids restricts evaluation to a subset (a warehouse-scoped user);
    # nil means every warehouse.
    def initialize(business, warehouse_ids: nil)
      @business      = business
      @warehouse_ids = warehouse_ids
    end

    def alerts
      levels      = movement_levels                       # { [product_id, wh_id] => qty }
      totals      = levels.each_with_object(Hash.new(0)) { |((pid, _), qty), h| h[pid] += qty }
      warehouses  = @business.warehouses.pluck(:id, :name).to_h
      central_ids = @business.warehouses.kind_central.pluck(:id).to_set
      # Products that actually move through the (restricted) warehouses — used so a
      # scoped user isn't shown catalog products that don't belong to their warehouses.
      present_ids = levels.keys.map(&:first).to_set

      results = []

      products.each do |product|
        # Only consider settings for warehouses the caller is allowed to see.
        settings = product.product_warehouse_settings
        settings = settings.select { |s| @warehouse_ids.include?(s.warehouse_id) } if @warehouse_ids

        warehouse_alerts = settings.select { |s| s.status_active? && s.low_stock_level.to_d.positive? }.filter_map do |setting|
          on_hand = levels[[ product.id, setting.warehouse_id ]] || 0
          next unless on_hand <= setting.low_stock_level

          Alert.new(
            product:          product,
            warehouse_id:     setting.warehouse_id,
            warehouse_name:   warehouses[setting.warehouse_id],
            on_hand:          on_hand,
            low_stock_level:  setting.low_stock_level,
            reorder_quantity: setting.reorder_quantity,
            notifiable:       setting.receive_low_stock_notification
          )
        end
        results.concat(warehouse_alerts)
        next if warehouse_alerts.any?

        # Legacy total alert: only while the central warehouse has no row of
        # its own (any status; checked on every row, not only the viewer's).
        next if product.product_warehouse_settings.any? { |s| central_ids.include?(s.warehouse_id) }
        # When restricted to specific warehouses, only the products actually
        # stocked there are eligible for the total-based fallback alert.
        next if @warehouse_ids && !present_ids.include?(product.id)

        total = totals[product.id] || 0
        next unless total <= product.reorder_level

        results << Alert.new(
          product:          product,
          warehouse_id:     nil,
          warehouse_name:   nil,
          on_hand:          total,
          low_stock_level:  product.reorder_level,
          reorder_quantity: product.reorder_quantity,
          notifiable:       true
        )
      end

      results.sort_by { |a| [ a.product.name, a.warehouse_name.to_s ] }
    end

    private

    def products
      @business.products
               .active
               .inventory_tracked
               .where(receive_low_stock_notification: true)
               .includes(:product_warehouse_settings, :parent_product, :default_supplier)
    end

    def movement_levels
      relation = InventoryMovement.for_business(@business)
      relation = relation.where(warehouse_id: @warehouse_ids) if @warehouse_ids
      relation.group(:product_id, :warehouse_id).sum(Arel.sql(SIGNED))
    end
  end
end
