require "rails_helper"

RSpec.describe FinancialSettlement, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:account) { create(:custody_account, business: business) }

  def build_receipt(total_cost: 500)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "employee_custody", funding_source: account)
    r.items.build(product: product, quantity: 1, unit_cost: total_cost)
    r.save!
    r
  end

  describe "Settleable derived financial status (via GoodsReceipt)" do
    it "is pending_settlement with no settlements" do
      receipt = build_receipt(total_cost: 1000)
      expect(receipt.total_settled_amount).to eq(0)
      expect(receipt).to be_pending_settlement
    end

    it "is partially_settled when settlements sum to less than the total" do
      receipt = build_receipt(total_cost: 1000)
      receipt.financial_settlements.create!(funding_source: account, amount: 300, settled_at: Time.current)

      expect(receipt.total_settled_amount).to eq(300)
      expect(receipt.remaining_settlement_amount).to eq(700)
      expect(receipt).to be_partially_settled
    end

    it "is settled once settlements sum to the full total, even across multiple funding sources (split settlement)" do
      receipt = build_receipt(total_cost: 1000)
      other_account = create(:custody_account, business: business)
      receipt.financial_settlements.create!(funding_source: account, amount: 600, settled_at: Time.current)
      receipt.financial_settlements.create!(funding_source: other_account, amount: 400, settled_at: Time.current)

      expect(receipt.total_settled_amount).to eq(1000)
      expect(receipt.remaining_settlement_amount).to eq(0)
      expect(receipt).to be_settled
    end

    it "returns to pending_settlement once a full reversal nets settlements back to zero" do
      receipt = build_receipt(total_cost: 1000)
      receipt.financial_settlements.create!(funding_source: account, amount: 1000, settled_at: Time.current)
      expect(receipt).to be_settled

      receipt.financial_settlements.create!(funding_source: account, amount: -1000, settled_at: Time.current)
      expect(receipt.total_settled_amount).to eq(0)
      expect(receipt).to be_pending_settlement
    end
  end

  describe "polymorphic settleable" do
    it "is scoped to a whitelisted settleable type" do
      expect(FinancialSettlement::SETTLEABLE_TYPES).to include("GoodsReceipt")
    end

    it "rejects a settleable type outside the whitelist" do
      receipt = build_receipt
      settlement = receipt.financial_settlements.build(funding_source: account, amount: 100, settled_at: Time.current)
      settlement.settleable_type = "Warehouse" # not a real settleable-capable model
      expect(settlement).not_to be_valid
      expect(settlement.errors[:settleable_type]).to be_present
    end
  end

  describe "immutability" do
    it "cannot be updated or destroyed after creation" do
      receipt = build_receipt
      settlement = receipt.financial_settlements.create!(funding_source: account, amount: 500, settled_at: Time.current)

      expect { settlement.update(amount: 1) }.to raise_error(ActiveRecord::ReadOnlyRecord)
      expect { settlement.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "validations" do
    it "rejects a zero amount" do
      receipt = build_receipt
      settlement = receipt.financial_settlements.build(funding_source: account, amount: 0, settled_at: Time.current)
      expect(settlement).not_to be_valid
    end

    it "rejects a funding source from a different business" do
      receipt = build_receipt
      other_account = create(:custody_account)
      settlement = receipt.financial_settlements.build(funding_source: other_account, amount: 100, settled_at: Time.current)
      expect(settlement).not_to be_valid
      expect(settlement.errors[:funding_source]).to be_present
    end
  end
end
