require "rails_helper"

RSpec.describe TowelTransfer, type: :model do
  let(:business) { create(:business) }
  let(:sales_branch)     { create(:branch, business: business, branch_type: "sales") }
  let(:other_sales_branch) { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch)   { create(:branch, business: business, branch_type: "laundry") }
  let(:hq_branch)         { create(:branch, business: business, branch_type: "headquarters") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

  def build_item(quantity: 10)
    TowelTransferItem.new(towel_type: towel_type, declared_quantity: quantity)
  end

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
      transfer = business.towel_transfers.build(source_branch: laundry_branch, destination_branch: sales_branch,
                                                towel_status: "clean", items: [ build_item ])
      expect(transfer.wash_conversion?).to be(true)
    end

    it "is false for a sales-branch-origin transfer" do
      transfer = business.towel_transfers.build(source_branch: sales_branch, destination_branch: laundry_branch,
                                                towel_status: "dirty", items: [ build_item ])
      expect(transfer.wash_conversion?).to be(false)
    end
  end

  describe "towel_status presence" do
    it "is invalid when the branch combination can't be inferred and no status is given" do
      transfer = business.towel_transfers.build(source_branch: hq_branch, destination_branch: sales_branch,
                                                towel_status: nil, items: [ build_item ])
      expect(transfer).not_to be_valid
      expect(transfer.errors[:towel_status]).to be_present
    end
  end

  it "has no loss/damage fields — recording a loss is done through TowelAdjustment, not TowelTransfer" do
    expect(TowelTransfer.column_names).not_to include("loss_quantity", "loss_reason")
    expect(TowelTransfer.new).not_to respond_to(:loss_quantity)
  end

  describe "has_at_least_one_item" do
    it "is invalid with zero items" do
      transfer = business.towel_transfers.build(source_branch: sales_branch, destination_branch: laundry_branch,
                                                towel_status: "dirty")
      expect(transfer).not_to be_valid
      expect(transfer.errors[:base]).to be_present
    end

    it "is valid with at least one item" do
      transfer = business.towel_transfers.build(source_branch: sales_branch, destination_branch: laundry_branch,
                                                towel_status: "dirty", items: [ build_item ])
      expect(transfer).to be_valid
    end
  end

  describe "#discrepancy" do
    it "is nil before the transfer has been received" do
      transfer = business.towel_transfers.create!(source_branch: sales_branch, destination_branch: laundry_branch,
                                                  towel_status: "dirty", items: [ build_item(quantity: 50) ])
      expect(transfer.discrepancy).to be_nil
    end

    it "sums discrepancy across every line item and is never negative" do
      transfer = business.towel_transfers.create!(source_branch: sales_branch, destination_branch: laundry_branch,
                                                  towel_status: "dirty", items: [ build_item(quantity: 50) ])
      transfer.items.first.update!(confirmed_quantity: 48)
      transfer.update!(status: "received")
      expect(transfer.discrepancy).to eq(2)
      expect(transfer.discrepancy).not_to be_negative
    end

    it "sums discrepancy across multiple line items" do
      other_towel_type = business.towel_types.create!(name: "Hand Towel")
      transfer = business.towel_transfers.create!(
        source_branch: sales_branch, destination_branch: laundry_branch, towel_status: "dirty",
        items: [ TowelTransferItem.new(towel_type: towel_type, declared_quantity: 50),
                TowelTransferItem.new(towel_type: other_towel_type, declared_quantity: 30) ]
      )
      transfer.items.find { |i| i.towel_type == towel_type }.update!(confirmed_quantity: 48)
      transfer.items.find { |i| i.towel_type == other_towel_type }.update!(confirmed_quantity: 30)
      transfer.update!(status: "received")
      expect(transfer.discrepancy).to eq(2)
    end
  end
end
