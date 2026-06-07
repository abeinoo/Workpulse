module Inventory
  module Reports
    # Inventory Movement report: every ledger movement in the filtered window,
    # in chronological order, with a running balance per (product, warehouse).
    # Original AND reversal movements both appear (audit-faithful).
    class Movements
      Row = Struct.new(
        :movement, :product, :warehouse, :direction, :reason,
        :quantity, :signed_quantity, :balance_after, keyword_init: true
      )

      def initialize(business, warehouse_ids: nil, product_id: nil, from: nil, to: nil)
        @business      = business
        @warehouse_ids = warehouse_ids
        @product_id    = product_id
        @from          = from
        @to            = to
      end

      def rows
        running = Hash.new(0)   # [product_id, warehouse_id] => balance
        scoped_movements.map do |movement|
          key = [ movement.product_id, movement.warehouse_id ]
          running[key] += movement.signed_quantity
          Row.new(
            movement:        movement,
            product:         movement.product,
            warehouse:       movement.warehouse,
            direction:       movement.direction,
            reason:          movement.reason,
            quantity:        movement.quantity,
            signed_quantity: movement.signed_quantity,
            balance_after:   running[key]
          )
        end
      end

      private

      def scoped_movements
        rel = @business.inventory_movements.includes(:product, :warehouse)
        rel = rel.where(warehouse_id: @warehouse_ids) if @warehouse_ids
        rel = rel.where(product_id: @product_id)       if @product_id.present?
        rel = rel.where("occurred_on >= ?", @from)     if @from.present?
        rel = rel.where("occurred_on <= ?", @to)       if @to.present?
        # Chronological so the running balance is meaningful.
        rel.order(:product_id, :warehouse_id, :occurred_on, :id)
      end
    end
  end
end
