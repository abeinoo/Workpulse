require "rails_helper"

# Product packaging levels (docs/inventory/multi_unit_nested_packaging_design.md §4; Decisions 1–3, 14).
RSpec.describe Inventory::Packaging::Configurator do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:razor)    { business.products.create!(name: "Razor", sku: "RZ-1", initial_cost_price: 1, average_cost_price: 1, unit_of_measure: "pieces") }
  let(:shampoo)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1, unit_of_measure: "ml") }

  def configure(product, *levels)
    described_class.new(product_id: product.id, actor: owner,
                        levels: levels.map { |unit, contains| { package_unit: unit, contains_quantity: contains } }).call
  end

  it "creates a four-level chain with base quantities, and sets the Amount to the innermost content" do
    result = configure(razor, [ "box", 10 ], [ "carton", 12 ], [ "case", 4 ], [ "pallet", 10 ])
    expect(result).to be_ok
    levels = razor.active_packaging_levels.map { |l| [ l.position, l.package_unit, l.contains_quantity.to_i, l.base_quantity.to_i ] }
    expect(levels).to eq([ [ 1, "box", 10, 10 ], [ 2, "carton", 12, 120 ], [ 3, "case", 4, 480 ], [ 4, "pallet", 10, 4800 ] ])
    expect(razor.reload.measure_amount).to eq(10)
    expect(AuditLog.where(auditable: razor, action: "packaging_configured").sole.actor).to eq(owner)
  end

  it "refuses a fifth level, duplicate units, invalid factors and excessive precision — changing nothing" do
    expect(configure(razor, [ "box", 10 ], [ "carton", 12 ], [ "case", 4 ], [ "pallet", 10 ], [ "pack", 2 ]).error).to include("at most 4")
    expect(configure(razor, [ "box", 10 ], [ "box", 12 ]).error).to include("only once")
    expect(configure(razor, [ "box", 0 ]).error).to include("more than zero")
    expect(configure(razor, [ "box", 10.5 ]).error).to include("whole number")
    expect(configure(razor, [ "box", 10 ], [ "carton", 1 ]).error).to include("at least 2")
    expect(configure(shampoo, [ "bottle", "355.1234" ]).error).to include("3 decimal places")
    expect(razor.packaging_levels).to be_empty
    expect(razor.reload.measure_amount).to be_nil
  end

  it "accepts a divisible inner content (355 ml bottle) and the database refuses a fifth active level" do
    expect(configure(shampoo, [ "bottle", "355" ], [ "case", 12 ])).to be_ok
    expect(shampoo.reload.measure_amount).to eq(355)
    expect do
      ProductPackagingLevel.create!(business: business, product: shampoo, position: 5, package_unit: "pallet",
                                    contains_quantity: 2, base_quantity: 8520)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect do
      ProductPackagingLevel.insert!({ business_id: business.id, product_id: shampoo.id, position: 5, package_unit: "pallet",
                                      contains_quantity: 2, base_quantity: 8520, status: "active", created_at: Time.current, updated_at: Time.current })
    end.to raise_error(ActiveRecord::StatementInvalid, /product_packaging_levels_position_range/)
  end

  it "keeps measure_amount in step with the innermost level: the database refuses a direct write" do
    configure(shampoo, [ "bottle", 355 ])
    error = nil
    ActiveRecord::Base.transaction(requires_new: true) do
      # The check is deferred to commit; make it immediate to see it inside the test transaction.
      ActiveRecord::Base.connection.execute("SET CONSTRAINTS products_check_packaging_structure IMMEDIATE")
      shampoo.update_column(:measure_amount, 500)
    rescue ActiveRecord::StatementInvalid => e
      error = e
      raise ActiveRecord::Rollback
    end
    expect(error.cause).to be_a(PG::CheckViolation)
    expect(error.cause.result.error_field(PG::PG_DIAG_CONSTRAINT_NAME)).to eq("products_measure_amount_matches_innermost_level")
    expect(shampoo.reload.measure_amount).to eq(355)
    shampoo.measure_amount = 400
    expect(shampoo).not_to be_valid
    expect(shampoo.errors[:measure_amount].join).to include("packaging")
  end

  it "a level is never edited in place (trigger), and products without packaging are unaffected" do
    configure(shampoo, [ "bottle", 355 ])
    level = shampoo.active_packaging_levels.first
    expect { ActiveRecord::Base.transaction(requires_new: true) { level.update_column(:contains_quantity, 500) } }
      .to raise_error(ActiveRecord::StatementInvalid, /never edited/)
    expect(level.reload.contains_quantity).to eq(355)
    expect { razor.update!(measure_amount: 3) }.not_to raise_error
  end

  it "several products configured in one enclosing transaction each succeed (the structure check stays deferred)" do
    ActiveRecord::Base.transaction do
      expect(configure(razor, [ "box", 10 ], [ "carton", 12 ])).to be_ok
      expect(configure(shampoo, [ "bottle", 355 ])).to be_ok
    end
    expect([ razor.reload.measure_amount, shampoo.reload.measure_amount ]).to eq([ 10, 355 ])
  end

  it "replacing a level retires the old one; a level holding sealed packages cannot be retired" do
    configure(razor, [ "box", 10 ], [ "carton", 12 ])
    receive_units!(product: razor, warehouse: warehouse, lines: [ [ "carton", 1, 120 ] ])
    result = configure(razor, [ "box", 10 ], [ "carton", 24 ])
    expect(result).not_to be_ok
    expect(result.error).to include("sealed packages")

    expect(configure(razor, [ "box", 10 ], [ "carton", 12 ], [ "case", 2 ])).to be_ok # adding outward is fine
    expect(razor.active_packaging_levels.pluck(:package_unit)).to eq(%w[box carton case])
  end

  it "configuring packaging never changes stock: existing stock stays loose" do
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: razor, quantity: 30, unit_cost: 1)
    Inventory::GoodsReceiptPoster.new(receipt).call
    expect { configure(razor, [ "box", 10 ]) }.not_to change(InventoryMovement, :count)
    expect(packaging_state(razor.reload, warehouse)).to eq("box" => 0, loose: 30, total: 30)
  end

  it "locks the base unit once stock has moved (Decision 2)" do
    expect(razor.update(unit_of_measure: "kg")).to be(true)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: razor, quantity: 1, unit_cost: 1)
    Inventory::GoodsReceiptPoster.new(receipt).call
    expect(razor.reload.update(unit_of_measure: "pieces")).to be(false)
    expect(razor.errors[:unit_of_measure].join).to include("Unit Conversion")
  end
end
