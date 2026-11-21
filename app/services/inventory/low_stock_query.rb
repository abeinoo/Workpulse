module Inventory
  # Computes low-stock alerts, evaluated PER WAREHOUSE only.
  #
  # Every Active per-warehouse row (ProductWarehouseSetting) with a threshold
  # above 0 is checked independently against its own low_stock_level and
  # suggests its own reorder_quantity — so a branch warehouse at zero stock
  # alerts even when another warehouse is well stocked. Threshold 0 = no alert
  # there. A product/warehouse pair without an Active row never alerts: there
  # is no product-level threshold, reorder quantity or notification flag, and
  # no fallback to one.
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
      # Detected alerts feed reports, KPIs, pickers and pages; only notifiable
      # ones belong on notification (dashboard) surfaces: the pair's own
      # receive_low_stock_notification.
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
      warehouses  = @business.warehouses.pluck(:id, :name).to_h

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
      end

      results.sort_by { |a| [ a.product.name, a.warehouse_name.to_s ] }
    end

    private

    def products
      @business.products.active.inventory_tracked.includes(:product_warehouse_settings, :default_supplier)
    end

    def movement_levels
      relation = InventoryMovement.for_business(@business)
      relation = relation.where(warehouse_id: @warehouse_ids) if @warehouse_ids
      relation.group(:product_id, :warehouse_id).sum(Arel.sql(SIGNED))
    end
  end
end
