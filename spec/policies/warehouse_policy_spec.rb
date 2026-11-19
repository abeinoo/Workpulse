require "rails_helper"

# Warehouse Architecture PR 5 (D4): only a business owner or a holder of
# access_all_warehouses (with manage_inventory) may create a warehouse.
# Editing and deleting stay manage_inventory, unchanged.
RSpec.describe WarehousePolicy do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main") }

  def user_with(*permissions, business: self.business) = user_with_stock_permissions(business, *permissions)
  def create?(user) = described_class.new(user, Warehouse).create?

  describe "#create?" do
    it "allows a business owner" do
      expect(create?(create(:user, :owner, business: business))).to be(true)
    end

    it "allows manage_inventory together with access_all_warehouses" do
      expect(create?(user_with(:view_inventory, :manage_inventory, :access_all_warehouses))).to be(true)
    end

    it "refuses manage_inventory alone" do
      expect(create?(user_with(:view_inventory, :manage_inventory))).to be(false)
    end

    it "refuses access_all_warehouses without manage_inventory" do
      expect(create?(user_with(:view_inventory, :access_all_warehouses))).to be(false)
    end

    it "refuses warehouse assignments alone" do
      user = user_with(:view_inventory, :manage_inventory)
      WarehouseAssignment.create!(user: user, warehouse: warehouse)
      expect(create?(user)).to be(false)
    end

    it "refuses a sales branch manager, and an area manager, through those links alone" do
      manager = user_with(:view_inventory, :manage_inventory)
      area    = user_with(:view_inventory, :manage_inventory)
      create(:branch, business: business, branch_type: "sales", branch_manager_id: manager.id, area_manager_id: area.id)

      expect(create?(manager)).to be(false)
      expect(create?(area)).to be(false)
    end

    it "gives new? the same answer" do
      expect(described_class.new(user_with(:view_inventory, :manage_inventory), Warehouse).new?).to be(false)
      expect(described_class.new(create(:user, :owner, business: business), Warehouse).new?).to be(true)
    end
  end

  describe "#classify? (an unclassified warehouse: company-wide structure, like creation)" do
    def classify?(user) = described_class.new(user, warehouse).classify?

    it "allows the owner and manage_inventory together with access_all_warehouses" do
      expect(classify?(create(:user, :owner, business: business))).to be(true)
      expect(classify?(user_with(:view_inventory, :manage_inventory, :access_all_warehouses))).to be(true)
    end

    it "refuses manage_inventory alone, a viewer, and a warehouse assignment alone" do
      assigned = user_with(:view_inventory, :manage_inventory)
      WarehouseAssignment.create!(user: assigned, warehouse: warehouse)

      expect(classify?(user_with(:view_inventory, :manage_inventory))).to be(false)
      expect(classify?(user_with(:view_inventory))).to be(false)
      expect(classify?(assigned)).to be(false)
    end
  end

  describe "#update? / #destroy? (unchanged: manage_inventory)" do
    it "allows manage_inventory and refuses view_inventory" do
      manager = user_with(:view_inventory, :manage_inventory)
      viewer  = user_with(:view_inventory)

      expect(described_class.new(manager, warehouse).update?).to be(true)
      expect(described_class.new(manager, warehouse).destroy?).to be(true)
      expect(described_class.new(viewer, warehouse).update?).to be(false)
    end
  end
end
