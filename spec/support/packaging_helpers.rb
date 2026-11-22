# Multi-unit / nested packaging fixtures (docs/inventory/multi_unit_nested_packaging_design.md).
# Everything goes through the real services: the Configurator defines levels,
# the posters write movements and packaging entries.
module PackagingHelpers
  # configure_packaging!(product, actor, [ "box", 10 ], [ "carton", 12 ]) — innermost first.
  def configure_packaging!(product, actor, *levels)
    result = Inventory::Packaging::Configurator.new(
      product_id: product.id, actor: actor,
      levels: levels.map { |unit, contains| { package_unit: unit, contains_quantity: contains } }
    ).call
    raise "packaging not configured: #{result.error}" unless result.ok?

    product.reload
  end

  def level_of(product, unit) = product.active_packaging_levels.find_by!(package_unit: unit)

  # lines: [[unit or nil (base), amount, unit cost per that unit], …]
  def receive_units!(product:, warehouse:, lines:, actor: nil, received_on: Date.current)
    receipt = product.business.goods_receipts.build(warehouse: warehouse, received_on: received_on)
    lines.each do |unit, amount, cost|
      receipt.items.build(product: product, entered_quantity: amount, packaging_level: unit && level_of(product, unit),
                          entered_unit_cost: cost)
    end
    result = Inventory::GoodsReceiptPoster.new(receipt, actor: actor).call
    raise "receipt not posted: #{receipt.errors.full_messages.to_sentence}" unless result.ok?

    receipt
  end

  # { "carton" => 1, "box" => 2, loose: 5, total: 145 } — derived from the ledgers.
  def packaging_state(product, warehouse)
    structure = Inventory::Packaging::Structure.for(product)
    balance   = Inventory::Packaging::Balance.load(structures: { product.id => structure }, warehouse_ids: [ warehouse.id ])
                                             .fetch([ warehouse.id, product.id ])
    structure.levels.to_h { |level| [ level.package_unit, balance.free[level.position] ] }
             .merge(loose: balance.loose, total: balance.total)
  end
end

RSpec.configure { |config| config.include PackagingHelpers }
