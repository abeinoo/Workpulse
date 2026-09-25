require "rails_helper"

RSpec.describe GoodsReceiptPolicy, type: :policy do
  let(:business)  { create(:business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product) do
    business.products.create!(name: "Hair Color", sku: "HC-1", initial_cost_price: 0, average_cost_price: 0)
  end

  def user_with(*permissions)
    role = create(:permission_role, business: business, permissions: permissions)
    create(:user, business: business, permission_role: role)
  end

  def receipt(approval_status: "approved")
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current, funding_source_kind: "supplier_credit")
    r.items.build(product: product, quantity: 5, unit_cost: 10)
    r.save!
    r.update_column(:approval_status, approval_status)
    r.reload
  end

  describe "#settle?" do
    it "is granted by approve_goods_receipts or manage_inventory" do
      expect(described_class.new(user_with("view_inventory", "approve_goods_receipts"), receipt).settle?).to be true
      expect(described_class.new(user_with("view_inventory", "manage_inventory"), receipt).settle?).to be true
    end

    it "is NOT granted to viewers, creators, confirmers, or employee-balance managers" do
      expect(described_class.new(user_with("view_inventory"), receipt).settle?).to be false
      expect(described_class.new(user_with("view_inventory", "create_goods_receipts"), receipt).settle?).to be false
      expect(described_class.new(user_with("view_inventory", "confirm_goods_receipts"), receipt).settle?).to be false
      expect(described_class.new(user_with("view_inventory", "view_employee_balances", "manage_employee_balances"), receipt).settle?).to be false
    end

    it "requires an approved, non-voided receipt with a remaining amount" do
      user = user_with("view_inventory", "manage_inventory")
      expect(described_class.new(user, receipt(approval_status: "pending_approval")).settle?).to be false
      expect(described_class.new(user, receipt(approval_status: "draft")).settle?).to be false

      voided = receipt
      voided.update_columns(voided_at: Time.current)
      expect(described_class.new(user, voided).settle?).to be false

      paid = receipt
      paid.financial_settlements.create!(source_kind: "company_cash", amount: 50, settled_at: Time.current)
      expect(described_class.new(user, paid).settle?).to be false
    end
  end

  describe "#reverse_settlement?" do
    it "is granted by void_goods_receipts or manage_inventory only" do
      expect(described_class.new(user_with("view_inventory", "void_goods_receipts"), receipt).reverse_settlement?).to be true
      expect(described_class.new(user_with("view_inventory", "manage_inventory"), receipt).reverse_settlement?).to be true
      expect(described_class.new(user_with("view_inventory", "approve_goods_receipts"), receipt).reverse_settlement?).to be false
      expect(described_class.new(user_with("view_inventory"), receipt).reverse_settlement?).to be false
    end
  end
end
