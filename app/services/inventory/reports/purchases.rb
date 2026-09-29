module Inventory
  module Reports
    # Purchase report: one row per posted goods receipt — confirmed (stock
    # received) and not voided. Draft, pending, rejected, cancelled and voided
    # receipts never count as purchases.
    #
    # Paid / outstanding come from the receipt's FinancialSettlement ledger
    # (Settleable), batched in one query; outstanding is what is still owed to
    # the supplier on that receipt.
    class Purchases
      Row = Struct.new(:receipt, :supplier, :purchase_request, :product_count, :total_value,
                       :paid_amount, :outstanding_amount, keyword_init: true)

      def self.posted_receipts(business)
        business.goods_receipts.active.where(status: "confirmed")
      end

      def initialize(business, warehouse_ids: nil, supplier_id: nil, from: nil, to: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @supplier_id   = supplier_id
        @from          = Movements.parse_date(from)
        @to            = Movements.parse_date(to)
      end

      def rows
        @rows ||= begin
          receipts = scoped_receipts.includes(:supplier, :purchase_request, items: :product).recent.to_a
          paid     = GoodsReceipt.settled_amounts_for(receipts.map(&:id))
          receipts.map do |receipt|
            total   = receipt.total_value
            settled = paid[receipt.id] || 0
            Row.new(receipt: receipt, supplier: receipt.supplier, purchase_request: receipt.purchase_request,
                    product_count: receipt.items.map(&:product_id).uniq.size,
                    total_value: total, paid_amount: settled,
                    outstanding_amount: [ total - settled, 0 ].max)
          end
        end
      end

      def total_value       = rows.sum(&:total_value)
      def total_paid        = rows.sum(&:paid_amount)
      def total_outstanding = rows.sum(&:outstanding_amount)

      # Headline totals without instantiating receipts (hub cards): two grouped
      # queries — receipt value from its items (GoodsReceipt#total_value) and
      # settled amount from the settlement ledger — same numbers as #rows.
      def summary
        @summary ||= begin
          ids     = scoped_receipts.select(:id)
          values  = GoodsReceiptItem.where(goods_receipt_id: ids).group(:goods_receipt_id).sum(:total_cost)
          settled = GoodsReceipt.settled_amounts_for(ids)
          { total_value: values.values.sum,
            outstanding: values.sum { |id, value| [ value - (settled[id] || 0), 0 ].max } }
        end
      end

      private

      def scoped_receipts
        rel = self.class.posted_receipts(@business)
        rel = rel.where(warehouse_id: @warehouse_ids) if @warehouse_ids
        rel = rel.where(supplier_id: @supplier_id)     if @supplier_id.present?
        rel = rel.where("received_on >= ?", @from)     if @from
        rel = rel.where("received_on <= ?", @to)       if @to
        rel
      end
    end
  end
end
