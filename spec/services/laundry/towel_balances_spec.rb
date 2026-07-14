require "rails_helper"

RSpec.describe Laundry::TowelBalances, type: :model do
  let(:business) { create(:business) }
  let(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
  let(:actor) { create(:user, business: business) }

  def fund(branch, status, quantity)
    Laundry::TowelAdjuster.new(actor: actor).call(
      towel_type: towel_type, branch: branch, status: status, adjustment_quantity: quantity, reason: "test setup"
    )
  end

  subject(:balances) { described_class.new(towel_type) }

  describe "#operational" do
    it "shows the clean balance for a sales branch" do
      fund(sales_branch, "clean", 50)
      fund(sales_branch, "dirty", 999) # never counted for a sales branch

      expect(balances.operational(sales_branch)).to eq(50)
    end

    it "shows the dirty balance for the laundry branch" do
      fund(laundry_branch, "dirty", 30)
      fund(laundry_branch, "clean", 999) # the edge case — never counted for the laundry

      expect(balances.operational(laundry_branch)).to eq(30)
    end

    it "never sums clean and dirty together" do
      fund(sales_branch, "clean", 20)
      fund(sales_branch, "dirty", 5)

      expect(balances.operational(sales_branch)).to eq(20) # not 25
    end
  end
end
