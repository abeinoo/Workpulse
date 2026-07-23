require "rails_helper"

RSpec.describe TowelTransferItem, type: :model do
  let(:business) { create(:business) }
  let(:other_business) { create(:business) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:other_towel_type) { business.towel_types.create!(name: "Hand Towel") }

  def build_transfer(*items)
    business.towel_transfers.build(source_branch: sales_branch, destination_branch: laundry_branch,
                                   towel_status: "dirty", items: items)
  end

  describe "quantity validations" do
    it "is invalid with a zero declared_quantity" do
      transfer = build_transfer(TowelTransferItem.new(towel_type: towel_type, declared_quantity: 0))
      expect(transfer).not_to be_valid
      expect(transfer.items.first.errors[:declared_quantity]).to be_present
    end

    it "is invalid with a negative declared_quantity" do
      transfer = build_transfer(TowelTransferItem.new(towel_type: towel_type, declared_quantity: -5))
      expect(transfer).not_to be_valid
    end

    it "is valid with a positive declared_quantity" do
      transfer = build_transfer(TowelTransferItem.new(towel_type: towel_type, declared_quantity: 10))
      expect(transfer).to be_valid
    end
  end

  describe "confirmed_quantity_not_more_than_declared" do
    it "is invalid when confirmed exceeds declared" do
      item = TowelTransferItem.new(towel_type: towel_type, declared_quantity: 50, confirmed_quantity: 55)
      transfer = build_transfer(item)
      expect(transfer).not_to be_valid
      expect(item.errors[:confirmed_quantity]).to be_present
    end

    it "is valid when confirmed equals or is less than declared" do
      expect(build_transfer(TowelTransferItem.new(towel_type: towel_type, declared_quantity: 50, confirmed_quantity: 50))).to be_valid
      expect(build_transfer(TowelTransferItem.new(towel_type: towel_type, declared_quantity: 50, confirmed_quantity: 48))).to be_valid
    end
  end

  describe "duplicate towel type prevention" do
    it "rejects two line items with the same towel type on one transfer" do
      transfer = build_transfer(
        TowelTransferItem.new(towel_type: towel_type, declared_quantity: 10),
        TowelTransferItem.new(towel_type: towel_type, declared_quantity: 5)
      )
      expect(transfer).not_to be_valid
      expect(transfer.items.last.errors[:towel_type_id]).to be_present
    end

    it "allows two different towel types on the same transfer" do
      transfer = build_transfer(
        TowelTransferItem.new(towel_type: towel_type, declared_quantity: 10),
        TowelTransferItem.new(towel_type: other_towel_type, declared_quantity: 5)
      )
      expect(transfer).to be_valid
    end

    it "enforces uniqueness at the database layer too" do
      transfer = build_transfer(TowelTransferItem.new(towel_type: towel_type, declared_quantity: 10))
      transfer.save!

      expect {
        transfer.items.create(towel_type: towel_type, declared_quantity: 5).tap do |dup|
          dup.save(validate: false)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "#discrepancy" do
    it "is nil before receipt" do
      item = TowelTransferItem.new(towel_type: towel_type, declared_quantity: 50)
      expect(item.discrepancy).to be_nil
    end

    it "is never negative because confirmed_quantity can never exceed declared_quantity" do
      item = TowelTransferItem.new(towel_type: towel_type, declared_quantity: 50, confirmed_quantity: 48)
      expect(item.discrepancy).to eq(2)
    end
  end

  it "rejects a towel type belonging to a different business" do
    foreign_towel_type = other_business.towel_types.create!(name: "Bath Towel")
    transfer = build_transfer(TowelTransferItem.new(towel_type: foreign_towel_type, declared_quantity: 10))
    expect(transfer).not_to be_valid
    expect(transfer.items.first.errors[:towel_type]).to be_present
  end
end
