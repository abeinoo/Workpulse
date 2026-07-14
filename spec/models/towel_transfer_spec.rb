require "rails_helper"

RSpec.describe TowelTransfer, type: :model do
  let(:business) { create(:business) }
  let(:sales_branch)     { create(:branch, business: business, branch_type: "sales") }
  let(:other_sales_branch) { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch)   { create(:branch, business: business, branch_type: "laundry") }
  let(:hq_branch)         { create(:branch, business: business, branch_type: "headquarters") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

  describe ".infer_towel_status" do
    it "infers dirty for a sales branch sending to the laundry" do
      expect(described_class.infer_towel_status(sales_branch, laundry_branch)).to eq("dirty")
    end

    it "infers clean for the laundry returning to a sales branch" do
      expect(described_class.infer_towel_status(laundry_branch, sales_branch)).to eq("clean")
    end

    it "infers clean for a direct sales-branch to sales-branch transfer" do
      expect(described_class.infer_towel_status(sales_branch, other_sales_branch)).to eq("clean")
    end

    it "returns nil for a non-standard combination, requiring a manual choice" do
      expect(described_class.infer_towel_status(hq_branch, sales_branch)).to be_nil
      expect(described_class.infer_towel_status(laundry_branch, hq_branch)).to be_nil
    end
  end

  describe "#wash_conversion?" do
    it "is true only for a laundry-origin transfer arriving clean" do
      transfer = business.towel_transfers.build(towel_type: towel_type, source_branch: laundry_branch,
                                                destination_branch: sales_branch, towel_status: "clean",
                                                declared_quantity: 10)
      expect(transfer.wash_conversion?).to be(true)
    end

    it "is false for a sales-branch-origin transfer" do
      transfer = business.towel_transfers.build(towel_type: towel_type, source_branch: sales_branch,
                                                destination_branch: laundry_branch, towel_status: "dirty",
                                                declared_quantity: 10)
      expect(transfer.wash_conversion?).to be(false)
    end
  end

  describe "towel_status presence" do
    it "is invalid when the branch combination can't be inferred and no status is given" do
      transfer = business.towel_transfers.build(towel_type: towel_type, source_branch: hq_branch,
                                                destination_branch: sales_branch, towel_status: nil,
                                                declared_quantity: 10)
      expect(transfer).not_to be_valid
      expect(transfer.errors[:towel_status]).to be_present
    end
  end

  it "has no loss/damage fields — recording a loss is done through TowelAdjustment, not TowelTransfer" do
    expect(TowelTransfer.column_names).not_to include("loss_quantity", "loss_reason")
    expect(TowelTransfer.new).not_to respond_to(:loss_quantity)
  end

  describe "confirmed_quantity_not_more_than_declared" do
    def build_transfer(declared:, confirmed:)
      business.towel_transfers.build(towel_type: towel_type, source_branch: sales_branch,
                                     destination_branch: laundry_branch, towel_status: "dirty",
                                     declared_quantity: declared, confirmed_quantity: confirmed)
    end

    it "is valid when confirmed equals declared" do
      expect(build_transfer(declared: 50, confirmed: 50)).to be_valid
    end

    it "is valid when confirmed is less than declared" do
      expect(build_transfer(declared: 50, confirmed: 48)).to be_valid
    end

    it "is invalid when confirmed exceeds declared" do
      transfer = build_transfer(declared: 50, confirmed: 55)
      expect(transfer).not_to be_valid
      expect(transfer.errors[:confirmed_quantity]).to be_present
    end

    it "is unaffected when confirmed_quantity is nil (not yet received)" do
      expect(build_transfer(declared: 50, confirmed: nil)).to be_valid
    end
  end

  describe "#discrepancy" do
    it "is never negative because confirmed_quantity can never exceed declared_quantity" do
      transfer = business.towel_transfers.create!(towel_type: towel_type, source_branch: sales_branch,
                                                   destination_branch: laundry_branch, towel_status: "dirty",
                                                   declared_quantity: 50)
      transfer.confirmed_quantity = 48
      expect(transfer.discrepancy).to eq(2)
      expect(transfer.discrepancy).not_to be_negative
    end
  end
end
