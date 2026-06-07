require "rails_helper"

RSpec.describe WarehouseAssignment, type: :model do
  let(:business) { create(:business) }
  let(:wh)       { business.warehouses.create!(name: "Main") }
  let(:user)     { create(:user, business: business) }

  it "is valid for a user + warehouse in the same business" do
    expect(WarehouseAssignment.new(user: user, warehouse: wh)).to be_valid
  end

  it "forbids assigning a warehouse from another business" do
    other = create(:business).warehouses.create!(name: "Other")
    a = WarehouseAssignment.new(user: user, warehouse: other)
    expect(a).not_to be_valid
    expect(a.errors[:warehouse_id]).to be_present
  end

  it "forbids duplicate assignments" do
    user.assigned_warehouses << wh
    dup = WarehouseAssignment.new(user: user, warehouse: wh)
    expect(dup).not_to be_valid
  end

  describe "User#inventory_warehouse_ids" do
    it "returns nil (all warehouses) for an owner regardless of assignments" do
      owner = create(:user, :super_admin, business: business)
      owner.assigned_warehouses << wh
      expect(owner.inventory_warehouse_ids).to be_nil
    end

    it "returns nil (all warehouses) for an unassigned non-owner" do
      expect(user.inventory_warehouse_ids).to be_nil
      expect(user.warehouse_scoped?).to be(false)
    end

    it "restricts to assigned warehouses once assigned" do
      wh2 = business.warehouses.create!(name: "Second")
      user.assigned_warehouses << wh
      expect(user.reload.inventory_warehouse_ids).to contain_exactly(wh.id)
      expect(user.warehouse_scoped?).to be(true)
      user.assigned_warehouses << wh2
      expect(user.reload.inventory_warehouse_ids).to contain_exactly(wh.id, wh2.id)
    end
  end
end
