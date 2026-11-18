require "rails_helper"

# PR 5a — voiding a transfer posts movements into BOTH of its warehouses, so
# StockTransferPolicy#void? requires access to both (it used to accept the
# one endpoint that made the transfer visible).
RSpec.describe StockTransferPolicy do
  let(:business)    { create(:business) }
  let(:other)       { create(:business) }
  let!(:source)     { business.warehouses.create!(name: "Source") }
  let!(:destination) { business.warehouses.create!(name: "Destination") }
  let!(:elsewhere)  { business.warehouses.create!(name: "Elsewhere") }
  let(:product)     { business.products.create!(name: "Shampoo", sku: "SH-1", average_cost_price: 5) }

  let(:transfer) do
    InventoryMovement.create!(business: business, product: product, warehouse: source, direction: :in,
                              reason: :opening_balance, quantity: 10, unit_cost: 5, occurred_on: Date.new(2026, 1, 1))
    business.stock_transfers.build(source_warehouse: source, destination_warehouse: destination,
                                   transferred_on: Date.new(2026, 1, 2)).tap do |t|
      t.items.build(product: product, quantity: 4)
      expect(Inventory::StockTransferPoster.new(t).call).to be_ok
    end
  end

  def mover(*warehouses, business: self.business)
    user_with_stock_permissions(business, :view_inventory, :manage_stock_transfers).tap do |user|
      warehouses.each { |warehouse| WarehouseAssignment.create!(user: user, warehouse: warehouse) }
    end
  end

  def void?(user, record = transfer) = described_class.new(user, record).void?

  describe "#void?" do
    it "permits a user with access to both warehouses" do
      expect(void?(mover(source, destination))).to be(true)
    end

    it "denies a user with access to the source only" do
      expect(void?(mover(source))).to be(false)
    end

    it "denies a user with access to the destination only" do
      expect(void?(mover(destination))).to be(false)
    end

    it "denies a user with access to neither warehouse" do
      expect(void?(mover(elsewhere))).to be(false)
    end

    it "keeps the unrestricted behaviour unchanged (no assignments = every warehouse, until PR 5's switch)" do
      expect(void?(mover)).to be(true)
    end

    it "denies a transfer of another business, whatever the user's access" do
      outsider = user_with_stock_permissions(other, :view_inventory, :manage_stock_transfers)
      expect(void?(outsider)).to be(false)
    end

    it "denies without the transfer permission even with access to both warehouses" do
      viewer = user_with_stock_permissions(business, :view_inventory).tap do |user|
        [ source, destination ].each { |warehouse| WarehouseAssignment.create!(user: user, warehouse: warehouse) }
      end
      expect(void?(viewer)).to be(false)
    end

    it "checks only the permission at the class level" do
      expect(void?(mover(source), StockTransfer)).to be(true)
    end
  end
end
