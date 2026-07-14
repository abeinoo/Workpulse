require "rails_helper"

RSpec.describe Laundry::BranchTowelConsumptionReport, type: :model do
  let(:business) { create(:business) }
  let(:branch_a) { create(:branch, business: business, branch_type: "sales", name: "Branch A") }
  let(:branch_b) { create(:branch, business: business, branch_type: "sales", name: "Branch B") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:other_towel_type) { business.towel_types.create!(name: "Hand Towel") }
  let(:actor) { create(:user, business: business) }

  def fund(branch, status, quantity, type: towel_type)
    Laundry::TowelAdjuster.new(actor: actor).call(towel_type: type, branch: branch, status: status,
                                                   adjustment_quantity: quantity, reason: "test setup")
  end

  def create_transfer(source:, destination:, quantity:, type: towel_type)
    status = TowelTransfer.infer_towel_status(source, destination) || "dirty"
    described = Laundry::TowelTransferCreator.create(actor: actor, params: {
      towel_type_id: type.id, source_branch_id: source.id, destination_branch_id: destination.id,
      towel_status: status, declared_quantity: quantity
    })
    described.transfer
  end

  def receive!(transfer, confirmed:)
    Laundry::TowelTransferCreator.new(transfer.reload).dispatch(actor: actor)
    Laundry::TowelTransferCreator.new(transfer.reload).receive(actor: actor, confirmed_quantity: confirmed)
  end

  def run(from: 1.month.ago.to_date, to: Date.current, **opts)
    described_class.new(business, from: from, to: to, **opts).call
  end

  before do
    business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: 1.year.ago)
    business.laundry_standard_cost_rates.create!(towel_type: other_towel_type, cost_per_towel: 1.5, effective_from: 1.year.ago)
  end

  it "counts a received sales-branch -> laundry transfer, using confirmed_quantity not declared_quantity" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 100)
    receive!(transfer, confirmed: 98)

    result = run
    row = result.rows.first
    expect(row.towel_count).to eq(98)
    expect(row.total_cost).to eq(98 * 1.5)
  end

  it "excludes a draft transfer" do
    fund(branch_a, "clean", 100)
    create_transfer(source: branch_a, destination: laundry_branch, quantity: 100)

    expect(run.rows).to be_empty
  end

  it "excludes a dispatched-but-not-received transfer" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 100)
    Laundry::TowelTransferCreator.new(transfer.reload).dispatch(actor: actor)

    expect(run.rows).to be_empty
  end

  it "excludes a cancelled transfer" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 100)
    Laundry::TowelTransferCreator.new(transfer.reload).cancel(actor: actor, reason: "wrong branch")

    expect(run.rows).to be_empty
  end

  it "excludes a received transfer that was later fully reversed" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 100)
    receive!(transfer, confirmed: 100)
    Laundry::TowelTransferCreator.new(transfer.reload).cancel(actor: actor, reason: "correction")

    expect(run.rows).to be_empty
  end

  it "excludes a laundry -> sales-branch transfer" do
    fund(laundry_branch, "dirty", 50)
    transfer = create_transfer(source: laundry_branch, destination: branch_a, quantity: 49)
    receive!(transfer, confirmed: 49)

    expect(run.rows).to be_empty
  end

  it "excludes a branch -> branch transfer" do
    fund(branch_a, "clean", 50)
    transfer = create_transfer(source: branch_a, destination: branch_b, quantity: 20)
    receive!(transfer, confirmed: 20)

    expect(run.rows).to be_empty
  end

  it "excludes a transfer that does not end at the central laundry (e.g. a non-laundry branch destination)" do
    hq = create(:branch, business: business, branch_type: "headquarters")
    fund(branch_a, "clean", 50)
    transfer = Laundry::TowelTransferCreator.create(actor: actor, params: {
      towel_type_id: towel_type.id, source_branch_id: branch_a.id, destination_branch_id: hq.id,
      towel_status: "dirty", declared_quantity: 20
    }).transfer
    receive!(transfer, confirmed: 20)

    expect(run.rows).to be_empty
  end

  it "uses the rate belonging to the exact towel type received — different types can have different rates" do
    # Overrides the outer before block's rates with more recent, distinct ones.
    business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: Time.current)
    business.laundry_standard_cost_rates.create!(towel_type: other_towel_type, cost_per_towel: 0.75, effective_from: Time.current)
    fund(branch_a, "clean", 100, type: towel_type)
    fund(branch_a, "clean", 200, type: other_towel_type)
    t1 = create_transfer(source: branch_a, destination: laundry_branch, quantity: 100, type: towel_type)
    t2 = create_transfer(source: branch_a, destination: laundry_branch, quantity: 200, type: other_towel_type)
    receive!(t1, confirmed: 100)
    receive!(t2, confirmed: 200)

    row = run.rows.first
    expect(row.total_cost).to eq((100 * 1.5) + (200 * 0.75)) # 150 + 150 = 300
  end

  it "aggregates multiple towel types for the same branch separately in the details, summed in the row" do
    fund(branch_a, "clean", 100, type: towel_type)
    fund(branch_a, "clean", 100, type: other_towel_type)
    t1 = create_transfer(source: branch_a, destination: laundry_branch, quantity: 30, type: towel_type)
    t2 = create_transfer(source: branch_a, destination: laundry_branch, quantity: 20, type: other_towel_type)
    receive!(t1, confirmed: 30)
    receive!(t2, confirmed: 20)

    row = run.rows.first
    expect(row.towel_count).to eq(50)
    expect(row.events.size).to eq(2)
  end

  it "aggregates multiple branches correctly, each as its own row" do
    fund(branch_a, "clean", 100)
    fund(branch_b, "clean", 100)
    ta = create_transfer(source: branch_a, destination: laundry_branch, quantity: 40)
    tb = create_transfer(source: branch_b, destination: laundry_branch, quantity: 25)
    receive!(ta, confirmed: 40)
    receive!(tb, confirmed: 25)

    result = run
    expect(result.rows.map { |r| [ r.branch.name, r.towel_count ] }.sort).to eq([ [ "Branch A", 40 ], [ "Branch B", 25 ] ])
    expect(result.total_towels).to eq(65)
  end

  it "filters by the receipt (laundry) timestamp, not creation or dispatch date" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 50)
    receive!(transfer, confirmed: 50)

    expect(run(from: 2.days.ago.to_date, to: 1.day.ago.to_date).rows).to be_empty
    expect(run(from: Date.current, to: Date.current).rows).not_to be_empty
  end

  it "never counts the same receipt twice even if queried repeatedly" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 50)
    receive!(transfer, confirmed: 50)

    expect(run.total_towels).to eq(run.total_towels)
    expect(run.rows.sum(&:towel_count)).to eq(50)
  end

  it "uses decimal-safe arithmetic for the standard cost calculation" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 3)
    receive!(transfer, confirmed: 3)

    expect(run.rows.first.total_cost).to eq(BigDecimal("4.5"))
    expect(run.rows.first.total_cost).to be_a(BigDecimal)
  end

  it "keeps historical cost unchanged after the current standard cost is later changed" do
    fund(branch_a, "clean", 100)
    transfer = create_transfer(source: branch_a, destination: laundry_branch, quantity: 100)
    receive!(transfer, confirmed: 100)
    original_total = run.rows.first.total_cost

    business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 5.0, effective_from: Time.current)

    expect(run.rows.first.total_cost).to eq(original_total)
    expect(run.rows.first.total_cost).to eq(100 * 1.5)
  end

  it "computes correctly when multiple standard rates applied within one period, flagging the row" do
    fund(branch_a, "clean", 100)
    t1 = create_transfer(source: branch_a, destination: laundry_branch, quantity: 40)
    receive!(t1, confirmed: 40) # at 1.5

    business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 2.0, effective_from: Time.current)

    t2 = create_transfer(source: branch_a, destination: laundry_branch, quantity: 10)
    receive!(t2, confirmed: 10) # at 2.0

    row = run.rows.first
    expect(row.multiple_rates).to be(true)
    expect(row.total_cost).to eq((40 * 1.5) + (10 * 2.0)) # never (50 * current_rate)
    expect(row.total_cost).not_to eq(50 * 2.0)
  end
end
