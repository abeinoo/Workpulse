require "rails_helper"

RSpec.describe SalesTransaction, type: :model do
  let(:business)     { create(:business) }
  let(:branch)       { create(:branch, business: business) }
  let(:sales_import) { SalesImport.create!(business: business, imported_by: create(:user, business: business), file_name: "x.csv", status: "imported") }

  def build_txn(attrs = {})
    SalesTransaction.new({
      business: business, sales_import: sales_import,
      transaction_date: Date.current, cashier_name: "Ahmed", branch_name: branch.name,
      payment_method_name: "Cash", amount: 100
    }.merge(attrs))
  end

  describe "transaction_type" do
    it "defaults to sale" do
      expect(build_txn.transaction_type).to eq("sale")
    end

    it "rejects a value outside sale/refund" do
      txn = build_txn(transaction_type: "voided")
      expect(txn).not_to be_valid
      expect(txn.errors[:transaction_type]).to be_present
    end
  end

  describe "#refund? / #sale?" do
    it "is false/true respectively for a sale" do
      txn = build_txn(transaction_type: "sale")
      expect(txn.refund?).to be(false)
      expect(txn.sale?).to be(true)
    end

    it "is true/false respectively for a refund" do
      txn = build_txn(transaction_type: "refund")
      expect(txn.refund?).to be(true)
      expect(txn.sale?).to be(false)
    end
  end

  describe "#signed_amount" do
    it "returns the positive amount unchanged for a sale" do
      txn = build_txn(transaction_type: "sale", amount: 500)
      expect(txn.signed_amount).to eq(500)
    end

    it "returns a negative value for a refund, while #amount stays positive" do
      txn = build_txn(transaction_type: "refund", amount: 181)
      expect(txn.amount).to eq(181)
      expect(txn.signed_amount).to eq(-181)
    end
  end

  describe "amount validation is unaffected by transaction_type" do
    it "still rejects a non-positive amount even for a refund row" do
      txn = build_txn(transaction_type: "refund", amount: -5)
      expect(txn).not_to be_valid
      expect(txn.errors[:amount]).to be_present
    end
  end

  describe "scopes" do
    it ".sales / .refunds partition correctly" do
      sale   = build_txn(transaction_type: "sale", reference_number: "S-1").tap(&:save!)
      refund = build_txn(transaction_type: "refund", reference_number: "R-1").tap(&:save!)

      expect(SalesTransaction.sales).to contain_exactly(sale)
      expect(SalesTransaction.refunds).to contain_exactly(refund)
    end
  end
end
