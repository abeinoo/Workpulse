require "rails_helper"

RSpec.describe Laundry::TowelAdjuster, type: :model do
  let(:business) { create(:business) }
  let(:branch) { create(:branch, business: business) }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:actor) { create(:user, business: business) }

  def balances
    Laundry::TowelBalances.new(towel_type)
  end

  before do
    Laundry::TowelTransferCreator.create(actor: actor, params: {
      towel_type_id: towel_type.id, source_branch_id: branch.id,
      destination_branch_id: create(:branch, business: business).id,
      towel_status: "clean", declared_quantity: 1
    })
  end

  it "records an explicit adjustment with the original value, delta, and reason — never a silent edit" do
    result = described_class.new(actor: actor).call(
      towel_type: towel_type, branch: branch, status: "clean",
      adjustment_quantity: 5, reason: "physical recount"
    )

    expect(result.ok?).to be(true)
    expect(result.adjustment.original_quantity).to eq(0)
    expect(result.adjustment.adjustment_quantity).to eq(5)
    expect(balances.at_branch(branch, "clean")).to eq(5)
  end

  it "rejects an adjustment that would drive the balance negative" do
    result = described_class.new(actor: actor).call(
      towel_type: towel_type, branch: branch, status: "clean",
      adjustment_quantity: -5, reason: "physical recount"
    )

    expect(result.ok?).to be(false)
    expect(balances.at_branch(branch, "clean")).to eq(0)
  end

  describe "#record_loss" do
    let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }

    def fund(target_branch, status, quantity)
      described_class.new(actor: actor).call(
        towel_type: towel_type, branch: target_branch, status: status,
        adjustment_quantity: quantity, reason: "test setup"
      )
    end

    it "reduces a sales branch's operational (clean) balance and records the tracking bucket, atomically" do
      fund(branch, "clean", 10)

      result = described_class.new(actor: actor).record_loss(
        towel_type: towel_type, branch: branch, adjustment_type: "lost", quantity: 3, reason: "went missing"
      )

      expect(result.ok?).to be(true)
      expect(result.adjustment.adjustment_type).to eq("lost")
      expect(result.adjustment.status).to eq("clean") # the operational bucket, not "lost"
      expect(balances.at_branch(branch, "clean")).to eq(7)  # operational balance reduced
      expect(balances.at_branch(branch, "lost")).to eq(3)   # tracking bucket increased
    end

    it "reduces the laundry's operational (dirty) balance for a damaged adjustment" do
      fund(laundry_branch, "dirty", 10)

      result = described_class.new(actor: actor).record_loss(
        towel_type: towel_type, branch: laundry_branch, adjustment_type: "damaged", quantity: 4, reason: "torn in the wash"
      )

      expect(result.ok?).to be(true)
      expect(balances.at_branch(laundry_branch, "dirty")).to eq(6)
      expect(balances.at_branch(laundry_branch, "damaged")).to eq(4)
    end

    it "rejects a quantity that would drive the operational balance negative" do
      fund(branch, "clean", 2)

      result = described_class.new(actor: actor).record_loss(
        towel_type: towel_type, branch: branch, adjustment_type: "lost", quantity: 5, reason: "went missing"
      )

      expect(result.ok?).to be(false)
      expect(balances.at_branch(branch, "clean")).to eq(2) # untouched
      expect(balances.at_branch(branch, "lost")).to eq(0)
    end

    it "preserves a full audit trail on the TowelAdjustment record" do
      fund(branch, "clean", 10)

      result = described_class.new(actor: actor).record_loss(
        towel_type: towel_type, branch: branch, adjustment_type: "lost", quantity: 3, reason: "went missing"
      )

      adjustment = result.adjustment
      expect(adjustment.branch).to eq(branch)
      expect(adjustment.towel_type).to eq(towel_type)
      expect(adjustment.original_quantity).to eq(10)
      expect(adjustment.adjustment_quantity).to eq(-3)
      expect(adjustment.resulting_quantity).to eq(7)
      expect(adjustment.adjustment_type).to eq("lost")
      expect(adjustment.reason).to eq("went missing")
      expect(adjustment.created_by).to eq(actor)
      expect(adjustment.created_at).to be_present
    end
  end
end
