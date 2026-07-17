require "rails_helper"

RSpec.describe FinancialSettlementService, type: :model do
  let(:business)  { create(:business) }
  let(:actor)     { create(:user, :super_admin, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:account) { create(:custody_account, business: business) }

  def build_receipt(total_cost: 1000)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: "employee_custody", funding_source: account)
    r.items.build(product: product, quantity: 1, unit_cost: total_cost)
    r.save!
    r
  end

  describe ".create" do
    it "creates a settlement against the settleable, without the caller touching FinancialSettlement directly" do
      receipt = build_receipt

      result = described_class.create(settleable: receipt, funding_source: account, amount: 400, actor: actor, notes: "partial")

      expect(result.ok?).to be(true)
      expect(result.settlement).to be_a(FinancialSettlement)
      expect(receipt.reload).to be_partially_settled
      expect(result.settlement.created_by).to eq(actor)
      expect(result.settlement.notes).to eq("partial")
    end

    it "returns a failed Result when the underlying settlement is invalid" do
      receipt = build_receipt
      other_business_account = create(:custody_account)

      result = described_class.create(settleable: receipt, funding_source: other_business_account, amount: 100, actor: actor)

      expect(result.ok?).to be(false)
      expect(result.error).to be_present
      expect(receipt.financial_settlements.count).to eq(0)
    end
  end

  describe ".reverse_all" do
    it "posts one equal-and-opposite settlement per existing settlement, leaving the originals untouched" do
      receipt = build_receipt(total_cost: 1000)
      described_class.create(settleable: receipt, funding_source: account, amount: 600, actor: actor)
      other_account = create(:custody_account, business: business)
      described_class.create(settleable: receipt, funding_source: other_account, amount: 400, actor: actor)
      expect(receipt.reload).to be_settled

      results = described_class.reverse_all(settleable: receipt, actor: actor)

      expect(results).to all(be_ok)
      expect(receipt.financial_settlements.count).to eq(4)
      expect(receipt.total_settled_amount).to eq(0)
      expect(receipt).to be_pending_settlement
    end

    it "is a no-op when there are no settlements to reverse" do
      receipt = build_receipt
      results = described_class.reverse_all(settleable: receipt, actor: actor)
      expect(results).to eq([])
    end
  end
end
