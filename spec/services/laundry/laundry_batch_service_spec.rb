require "rails_helper"

RSpec.describe Laundry::LaundryBatchService, type: :model do
  let(:business) { create(:business) }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:actor) { create(:user, business: business) }

  def balances
    Laundry::TowelBalances.new(towel_type)
  end

  def build_batch
    described_class.create(actor: actor, laundry_branch_id: laundry_branch.id,
                           towel_type_id: towel_type.id).batch
  end

  it "start consumes dirty towels out of the laundry branch's balance" do
    batch = build_batch
    described_class.new(batch).start(actor: actor, input_quantity: 200)

    expect(balances.at_branch(laundry_branch, "dirty")).to eq(-200)
  end

  it "complete posts clean/damaged/disposed IN entries and fails the reconciliation check when quantities don't add up" do
    batch = build_batch
    described_class.new(batch).start(actor: actor, input_quantity: 200)

    bad = described_class.new(batch.reload).complete(actor: actor, output_clean_quantity: 190,
                                                      damaged_quantity: 2, disposed_quantity: 1)
    expect(bad.ok?).to be(false)

    good = described_class.new(batch.reload).complete(actor: actor, output_clean_quantity: 197,
                                                       damaged_quantity: 2, disposed_quantity: 1)
    expect(good.ok?).to be(true)
    expect(balances.at_branch(laundry_branch, "clean")).to eq(197)
    expect(balances.at_branch(laundry_branch, "damaged")).to eq(2)
    expect(balances.at_branch(laundry_branch, "disposed")).to eq(1)
  end

  it "reverse posts compensating entries and voids the batch without mutating its recorded quantities" do
    batch = build_batch
    described_class.new(batch).start(actor: actor, input_quantity: 200)
    described_class.new(batch.reload).complete(actor: actor, output_clean_quantity: 197,
                                               damaged_quantity: 2, disposed_quantity: 1)

    result = described_class.new(batch.reload).reverse(actor: actor, reason: "miscounted output")

    expect(result.ok?).to be(true)
    expect(batch.reload).to be_voided
    expect(batch.output_clean_quantity).to eq(197) # historical record untouched
    expect(balances.at_branch(laundry_branch, "clean")).to eq(0)
    expect(balances.at_branch(laundry_branch, "dirty")).to eq(0)
  end
end
