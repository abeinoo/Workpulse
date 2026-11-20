module Inventory
  # Read-only figures for product/warehouse availability pairs, shared by the
  # warehouse Products tab and the product page's Warehouse Availability card.
  #
  # A pair is (product, warehouse, setting-or-nil): no setting = Not
  # Configured. On-hand and reserved come from the ledger and the open stock
  # issues in two grouped queries for the whole set — never one per row.
  #
  # Nothing here reads a product-level (legacy) threshold: a pair without an
  # availability row shows no low-stock or reorder value at all.
  class AvailabilityFigures
    Pair = Struct.new(:product, :warehouse, :setting, :on_hand, :reserved, keyword_init: true) do
      # Sales branch warehouses (Warehouse#availability_included_by_default?):
      #   "included" (no row, or Active) / "excluded" (Inactive).
      # Central / unclassified: "active" / "inactive" / "not_configured".
      def state
        if included_by_default?
          inactive? ? "excluded" : "included"
        else
          setting ? setting.status : "not_configured"
        end
      end

      def included_by_default? = warehouse.availability_included_by_default?
      def excluded? = included_by_default? && inactive?

      def configured? = !setting.nil?
      def active?     = setting&.status_active? || false
      def inactive?   = setting&.status_inactive? || false

      # Low-stock settings apply only to tracked products.
      def tracked? = product.track_inventory?

      # The target detection rule (plan §3.4): Active pair, active warehouse,
      # tracked product, threshold > 0, on-hand at or below it. Shown as a
      # page indicator; notification preference never hides it.
      def low_stock?
        active? && warehouse.active? && tracked? &&
          setting.low_stock_level.to_d.positive? && on_hand.to_d <= setting.low_stock_level.to_d
      end
    end

    # pairs: [[product, warehouse, setting_or_nil], ...]
    def self.build(pairs)
      pairs = Array(pairs)
      return [] if pairs.empty?

      product_ids   = pairs.map { |product, _, _| product.id }.uniq
      warehouse_ids = pairs.map { |_, warehouse, _| warehouse.id }.uniq
      on_hand = InventoryMovement.where(product_id: product_ids, warehouse_id: warehouse_ids)
                                 .group(:product_id, :warehouse_id)
                                 .sum(Arel.sql(StockLevels::SIGNED))
      reserved = StockAvailability.reserved_by(warehouse_ids: warehouse_ids, product_ids: product_ids)

      pairs.map do |product, warehouse, setting|
        Pair.new(product: product, warehouse: warehouse, setting: setting,
                 on_hand: on_hand[[ product.id, warehouse.id ]].to_d,
                 reserved: reserved[[ warehouse.id, product.id ]].to_d)
      end
    end
  end
end
