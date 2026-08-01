require "rails_helper"

RSpec.describe PaymentMethod do
  describe ".included_in_pos_verification" do
    it "returns only payment methods flagged include_in_pos_verification" do
      business = create(:business)
      visa = PaymentMethod.create!(business: business, name: "Card", settlement_type: "card",
                                    include_in_pos_verification: true)
      PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash",
                             include_in_pos_verification: false)

      expect(PaymentMethod.included_in_pos_verification).to eq([ visa ])
    end
  end

  it "defaults include_in_pos_verification to false" do
    business = create(:business)
    pm = PaymentMethod.create!(business: business, name: "Wallet", settlement_type: "ewallet")

    expect(pm.include_in_pos_verification).to be false
  end
end
