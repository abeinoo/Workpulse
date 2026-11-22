module Inventory
  module Packaging
    # The only writer of inventory_packaging_entries: one row per planner step,
    # for one product in one warehouse, tied to the document (source) and, when
    # the step accompanies one, its inventory movement.
    module EntryWriter
      module_function

      def write!(steps:, structure:, business:, product_id:, warehouse_id:, source:, occurred_on:, movement: nil)
        steps.each do |step|
          InventoryPackagingEntry.create!(
            business:           business,
            product_id:         product_id,
            warehouse_id:       warehouse_id,
            packaging_level_id: structure.at(step.position).id,
            package_delta:      step.delta,
            kind:               step.kind.to_s,
            inventory_movement: movement,
            source:             source,
            occurred_on:        occurred_on
          )
        end
      end
    end
  end
end
