module Inventory
  module Packaging
    # A product's active packaging chain, read once (docs/inventory/multi_unit_nested_packaging_design.md §4).
    # Levels are ordered innermost (position 1) to outermost; a product without
    # levels is "loose only" and every packaging operation is a no-op for it.
    class Structure
      Level = Data.define(:id, :position, :package_unit, :contains, :base_quantity) do
        def self.from(record)
          new(id: record.id, position: record.position, package_unit: record.package_unit,
              contains: record.contains_quantity.to_d, base_quantity: record.base_quantity.to_d)
        end
      end

      attr_reader :product_id, :levels

      # { product_id => Structure } for every given product (one query).
      def self.for_products(product_ids)
        ids = Array(product_ids).compact.uniq
        rows = ProductPackagingLevel.active.where(product_id: ids).order(:product_id, :position).group_by(&:product_id)
        ids.index_with { |id| new(id, rows.fetch(id, []).map { |r| Level.from(r) }) }
      end

      def self.for(product)
        for_products([ product.id ]).fetch(product.id)
      end

      def initialize(product_id, levels)
        @product_id = product_id
        @levels     = levels.sort_by(&:position).freeze
      end

      def packaged? = levels.any?
      def depth     = levels.size
      def level(id) = levels.find { |l| l.id == id.to_i }
      def at(position) = levels.find { |l| l.position == position }
      def outermost = levels.last

      # Base units in one package of the level (1 for the base unit itself).
      def factor(level_id)
        return 1.to_d if level_id.blank?

        level(level_id)&.base_quantity || raise(ArgumentError, "packaging level #{level_id} is not active on product #{product_id}")
      end
    end
  end
end
