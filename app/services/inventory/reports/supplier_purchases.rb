module Inventory
  module Reports
    # Supplier report: purchases per supplier — receipts, products, quantity,
    # value, last purchase date, outstanding balance and top purchased
    # products. Built on Reports::Purchases so it counts exactly the same
    # posted receipts (confirmed, not voided) and the same settlement ledger.
    class SupplierPurchases
      TOP_PRODUCTS = 3

      Row = Struct.new(:supplier, :receipt_count, :product_count, :total_quantity, :total_value,
                       :last_purchase_on, :outstanding_amount, :top_products, keyword_init: true)

      def initialize(business, warehouse_ids: nil, supplier_id: nil, from: nil, to: nil)
        @purchases = Purchases.new(business, warehouse_ids: warehouse_ids, supplier_id: supplier_id,
                                              from: from, to: to)
      end

      def rows
        @rows ||= @purchases.rows.group_by(&:supplier).filter_map do |supplier, purchase_rows|
          next if supplier.nil?

          items = purchase_rows.flat_map { |r| r.receipt.items }
          Row.new(
            supplier:           supplier,
            receipt_count:      purchase_rows.size,
            product_count:      items.map(&:product_id).uniq.size,
            total_quantity:     items.sum { |i| i.quantity.to_d },
            total_value:        purchase_rows.sum(&:total_value),
            last_purchase_on:   purchase_rows.map { |r| r.receipt.received_on }.max,
            outstanding_amount: purchase_rows.sum(&:outstanding_amount),
            top_products:       top_products(items)
          )
        end.sort_by { |row| -row.total_value }
      end

      def grand_total       = rows.sum(&:total_value)
      def total_outstanding = rows.sum(&:outstanding_amount)

      private

      # [[product, value], ...] by purchase value, highest first. Products are
      # already preloaded with the receipt items (Purchases#rows).
      def top_products(items)
        items.group_by(&:product)
             .map { |product, lines| [ product, lines.sum { |l| l.total_cost.to_d } ] }
             .sort_by { |(_, value)| -value }
             .first(TOP_PRODUCTS)
      end
    end
  end
end
