require "rails_helper"

RSpec.describe GoodsReceipt, type: :model do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end
  let(:account) { create(:custody_account, business: business) }

  def build_receipt(funding_source_kind:, funding_source: nil)
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current,
                                      funding_source_kind: funding_source_kind, funding_source: funding_source)
    r.items.build(product: product, quantity: 1, unit_cost: 1)
    r
  end

  describe "funding source validations" do
    it "reports a missing custody account (not a missing selection) when the kind is employee_custody" do
      receipt = build_receipt(funding_source_kind: "employee_custody")
      expect(receipt).not_to be_valid
      expect(receipt.errors[:base]).to eq(
        [ "You do not have a custody account. You cannot use Employee Custody as the funding source." ]
      )
      expect(receipt.errors[:funding_source]).to be_empty
    end

    it "requires a funding source kind to be chosen" do
      receipt = build_receipt(funding_source_kind: nil)
      expect(receipt).not_to be_valid
      expect(receipt.errors.full_messages).to include("Funding source must be selected")
    end

    it "is valid when employee_custody has a linked custody account" do
      receipt = build_receipt(funding_source_kind: "employee_custody", funding_source: account)
      expect(receipt).to be_valid
    end

    %w[supplier_credit company_cash bank_account].each do |kind|
      it "rejects a linked employee when the kind is #{kind}" do
        receipt = build_receipt(funding_source_kind: kind, funding_source: account)
        expect(receipt).not_to be_valid
        expect(receipt.errors[:funding_source]).to include(match(/must be blank/))
      end

      it "is valid for #{kind} with no employee linked" do
        receipt = build_receipt(funding_source_kind: kind)
        expect(receipt).to be_valid
      end
    end
  end

  describe "financial_status" do
    it "defaults new receipts to pending_settlement, independent of inventory status" do
      receipt = build_receipt(funding_source_kind: "supplier_credit")
      receipt.save!
      expect(receipt).to be_pending_settlement
      expect(receipt).to be_draft
    end
  end
end
