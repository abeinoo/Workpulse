require "rails_helper"

# The pure packaging planner (docs/inventory/multi_unit_nested_packaging_design.md §6): no
# database — a Structure and a Balance in, steps and a new balance out.
RSpec.describe Inventory::Packaging::Planner do
  Level = Inventory::Packaging::Structure::Level

  # Razor blades: 1 box = 10 pcs, 1 carton = 12 boxes (= 120 pcs).
  let(:razors) do
    Inventory::Packaging::Structure.new(1, [ Level.new(id: 11, position: 1, package_unit: "box", contains: 10.to_d, base_quantity: 10.to_d),
                                             Level.new(id: 12, position: 2, package_unit: "carton", contains: 12.to_d, base_quantity: 120.to_d) ])
  end
  # Shampoo: 1 bottle = 355 ml.
  let(:shampoo) do
    Inventory::Packaging::Structure.new(2, [ Level.new(id: 21, position: 1, package_unit: "bottle", contains: 355.to_d, base_quantity: 355.to_d) ])
  end

  def balance(structure, total:, **free)
    Inventory::Packaging::Balance.new(structure, total: total, free: free)
  end

  def state(planner) = [ planner.balance.free, planner.balance.loose, planner.balance.total ]

  it "issuing 3 boxes from 1 carton opens the carton: 9 boxes (90)" do
    plan = described_class.new(balance(razors, total: 120, 2 => 1)).take_packages(1, 3)
    expect(state(plan)).to eq([ { 1 => 9, 2 => 0 }, 0, 90 ])
    expect(plan.steps.map(&:to_h)).to eq([ { kind: :breakdown, position: 2, delta: -1 }, { kind: :breakdown, position: 1, delta: 12 },
                                           { kind: :moved, position: 1, delta: -3 } ])
  end

  # 9 boxes + 5 loose = 95 − 15 = 80: the 5 loose pieces first, then one box
  # (10) → 8 boxes + 0 loose. From 9 boxes alone (90): two boxes → 7 + 5 (75).
  it "15 pieces: loose first, then the fewest boxes (95 → 8 boxes; 90 → 7 boxes + 5 pcs)" do
    plan = described_class.new(balance(razors, total: 95, 1 => 9)).take_base(15)
    expect(state(plan)).to eq([ { 1 => 8, 2 => 0 }, 0, 80 ])
    expect(plan.steps.map(&:to_h)).to eq([ { kind: :breakdown, position: 1, delta: -1 } ])
    plan = described_class.new(balance(razors, total: 90, 1 => 9)).take_base(15)
    expect(state(plan)).to eq([ { 1 => 7, 2 => 0 }, 5, 75 ])
  end

  it "15 pieces from 1 carton → 10 boxes + 5 pcs (105)" do
    plan = described_class.new(balance(razors, total: 120, 2 => 1)).take_base(15)
    expect(state(plan)).to eq([ { 1 => 10, 2 => 0 }, 5, 105 ])
  end

  it "a strict box request never takes loose pieces: 0 boxes + 25 pcs refuses 1 box" do
    expect { described_class.new(balance(razors, total: 25)).take_packages(1, 1) }
      .to raise_error(described_class::Refusal) { |e| expect(e.details).to include(package_unit: "box", needed: 1, available: 0) }
  end

  it "the outermost level comes only from free packages of that level" do
    expect { described_class.new(balance(razors, total: 240, 1 => 24)).take_packages(2, 1) }
      .to raise_error(described_class::Refusal) { |e| expect(e.code).to eq(:insufficient_packages) }
  end

  it "shampoo: 12 sealed → 100 ml → 11 sealed + 255 ml; → 200 ml → 11 sealed + 55 ml" do
    plan = described_class.new(balance(shampoo, total: 4260, 1 => 12)).take_base(100)
    expect(state(plan)).to eq([ { 1 => 11 }, 255, 4160 ])
    plan.take_base(200)
    expect(state(plan)).to eq([ { 1 => 11 }, 55, 3960 ])
  end

  it "refuses more than the total and fractional packages" do
    expect { described_class.new(balance(shampoo, total: 100)).take_base(101) }
      .to raise_error(described_class::Refusal) { |e| expect(e.code).to eq(:insufficient_stock) }
    expect { described_class.new(balance(razors, total: 120, 2 => 1)).take_packages(1, 1.5) }
      .to raise_error(described_class::Refusal) { |e| expect(e.code).to eq(:not_whole_packages) }
  end

  it "voiding an inflow removes the packages still free and the rest as base quantity, never resealing" do
    # 3 cartons + 29 boxes (650); remove a 5-carton receipt → 3 cartons + 240 pcs from opened boxes.
    plan = described_class.new(balance(razors, total: 650, 2 => 3, 1 => 29)).remove_inflow(2, 5)
    expect(state(plan)).to eq([ { 1 => 5, 2 => 0 }, 0, 50 ])
  end

  it "opening packages never changes the total; corrections change packaging only" do
    plan = described_class.new(balance(shampoo, total: 3140, 1 => 8))
    plan.correct(1, -1)
    expect(state(plan)).to eq([ { 1 => 7 }, 655, 3140 ])
    expect { described_class.new(balance(shampoo, total: 100, 1 => 0)).correct(1, 1).check! }
      .to raise_error(described_class::Refusal) { |e| expect(e.code).to eq(:negative_loose) }
  end
end
