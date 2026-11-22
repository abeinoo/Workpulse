module Inventory
  module Packaging
    # One product's packaging state in one warehouse, derived from the ledgers:
    #   total    = SUM(signed quantity) of inventory_movements (base units)
    #   free[p]  = SUM(package_delta) of inventory_packaging_entries at level p
    #   loose    = total − Σ free[p] × base_quantity[p]
    class Balance
      attr_reader :structure, :free
      attr_accessor :total

      def initialize(structure, total:, free: {})
        @structure = structure
        @total     = total.to_d
        @free      = structure.levels.to_h { |l| [ l.position, free.fetch(l.position, 0).to_i ] }
      end

      def loose
        total - structure.levels.sum(0.to_d) { |l| free[l.position] * l.base_quantity }
      end

      def consistent? = free.values.all? { |v| v >= 0 } && loose >= 0

      def dup_state = self.class.new(structure, total: total, free: free.dup)

      # { [warehouse_id, product_id] => Balance } for packaged products (two queries).
      def self.load(structures:, warehouse_ids:)
        packaged = structures.values.select(&:packaged?)
        return {} if packaged.empty?

        product_ids   = packaged.map(&:product_id)
        warehouse_ids = Array(warehouse_ids).compact.uniq
        totals = StockAvailability.on_hand_by(warehouse_ids: warehouse_ids, product_ids: product_ids)
        sums   = InventoryPackagingEntry.where(product_id: product_ids, warehouse_id: warehouse_ids)
                                        .group(:warehouse_id, :product_id, :packaging_level_id).sum(:package_delta)

        packaged.each_with_object({}) do |structure, map|
          warehouse_ids.each do |warehouse_id|
            free = structure.levels.to_h { |l| [ l.position, sums[[ warehouse_id, structure.product_id, l.id ]].to_i ] }
            map[[ warehouse_id, structure.product_id ]] =
              new(structure, total: totals[[ warehouse_id, structure.product_id ]].to_d, free: free)
          end
        end
      end
    end
  end
end
