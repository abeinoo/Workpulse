require "rails_helper"

RSpec.describe LaundryStandardCostRate, type: :model do
  let(:business) { create(:business) }
  let(:towel_type) { business.towel_types.create!(name: "Drying Towel") }
  let(:other_towel_type) { business.towel_types.create!(name: "Hot Towel") }

  it "requires cost_per_towel to be zero or more" do
    rate = business.laundry_standard_cost_rates.build(towel_type: towel_type, cost_per_towel: -1, effective_from: Time.current)
    expect(rate).not_to be_valid
  end

  it "allows a zero cost" do
    rate = business.laundry_standard_cost_rates.build(towel_type: towel_type, cost_per_towel: 0, effective_from: Time.current)
    expect(rate).to be_valid
  end

  it "requires a towel type" do
    rate = business.laundry_standard_cost_rates.build(cost_per_towel: 1.5, effective_from: Time.current)
    expect(rate).not_to be_valid
    expect(rate.errors[:towel_type]).to be_present
  end

  it "rejects a towel type from a different business" do
    other_business_towel_type = create(:business).towel_types.create!(name: "Other Biz Towel")
    rate = business.laundry_standard_cost_rates.build(towel_type: other_business_towel_type,
                                                      cost_per_towel: 1.5, effective_from: Time.current)
    expect(rate).not_to be_valid
    expect(rate.errors[:towel_type]).to be_present
  end

  describe ".effective_for" do
    it "returns nil when no rate has ever been configured for that towel type" do
      expect(described_class.effective_for(business, towel_type: towel_type, at: Time.current)).to be_nil
    end

    it "returns the latest rate whose effective_from is at or before the given time" do
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.50, effective_from: 10.days.ago)
      later = business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.75, effective_from: 2.days.ago)

      expect(described_class.effective_for(business, towel_type: towel_type, at: Time.current).cost_per_towel).to eq(1.75)
      expect(described_class.effective_for(business, towel_type: towel_type, at: Time.current)).to eq(later)
    end

    it "resolves historical rates correctly — a rate change does not affect the past" do
      old_rate = business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.50, effective_from: 40.days.ago)
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.75, effective_from: 2.days.ago)

      expect(described_class.effective_for(business, towel_type: towel_type, at: 20.days.ago).cost_per_towel).to eq(old_rate.cost_per_towel)
    end

    it "keeps each towel type's rate independent — a rate change for one type does not affect another" do
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.50, effective_from: 10.days.ago)
      business.laundry_standard_cost_rates.create!(towel_type: other_towel_type, cost_per_towel: 0.75, effective_from: 10.days.ago)

      expect(described_class.effective_for(business, towel_type: towel_type, at: Time.current).cost_per_towel).to eq(1.50)
      expect(described_class.effective_for(business, towel_type: other_towel_type, at: Time.current).cost_per_towel).to eq(0.75)
    end
  end

  describe ".current_by_towel_type" do
    it "returns the current rate for each towel type in one batch, avoiding N+1" do
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.50, effective_from: 10.days.ago)
      business.laundry_standard_cost_rates.create!(towel_type: other_towel_type, cost_per_towel: 0.75, effective_from: 10.days.ago)

      result = described_class.current_by_towel_type(business, [ towel_type.id, other_towel_type.id ])

      expect(result[towel_type.id].cost_per_towel).to eq(1.50)
      expect(result[other_towel_type.id].cost_per_towel).to eq(0.75)
    end
  end
end
