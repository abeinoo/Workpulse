module Inventory
  module Reports
    # Supplier Purchases report: total purchases, distinct products and purchase
    # value per supplier, filterable by supplier and date range. Only counts
    # receipts in the accessible warehouses, and excludes voided receipts.
    class SupplierPurchases
      Row = Struct.new(:supplier, :receipt_count, :product_count, :total_quantity, :total_value, keyword_init: true)

      def initialize(business, warehouse_ids: nil, supplier_id: nil, from: nil, to: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @supplier_id   = supplier_id
        @from          = from
        @to            = to
      end

      def rows
        receipts = scoped_receipts.includes(:supplier, items: :product).to_a
        receipts.group_by(&:supplier).filter_map do |supplier, supplier_receipts|
          next if supplier.nil?

          items = supplier_receipts.flat_map(&:items)
          Row.new(
            supplier:       supplier,
            receipt_count:  supplier_receipts.size,
            product_count:  items.map(&:product_id).uniq.size,
            total_quantity: items.sum { |i| i.quantity.to_d },
            total_value:    items.sum { |i| i.total_cost.to_d }
          )
        end.sort_by { |row| -row.total_value }
      end

      def grand_total
        rows.sum(&:total_value)
      end

      private

      def scoped_receipts
        rel = @business.goods_receipts.active.where.not(supplier_id: nil)
        rel = rel.where(warehouse_id: @warehouse_ids) if @warehouse_ids
        rel = rel.where(supplier_id: @supplier_id)     if @supplier_id.present?
        rel = rel.where("received_on >= ?", @from)     if @from.present?
        rel = rel.where("received_on <= ?", @to)       if @to.present?
        rel
      end
    end
  end
end
