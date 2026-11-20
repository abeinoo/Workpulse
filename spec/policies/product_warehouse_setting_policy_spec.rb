require "rails_helper"

RSpec.describe ProductWarehouseSettingPolicy do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let!(:central)    { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:nasr_wh)    { business.warehouses.create!(name: "Nasr City WH", kind: "central") }
  let!(:foreign_wh) { other.warehouses.create!(name: "Foreign") }
  let(:product)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 1, average_cost_price: 1) }
  let(:foreign_product) { other.products.create!(name: "X", sku: "X-1", initial_cost_price: 1, average_cost_price: 1) }
  let!(:central_row) { product.product_warehouse_settings.create!(warehouse: central, low_stock_level: 3, reorder_quantity: 10) }
  let!(:nasr_row)    { product.product_warehouse_settings.create!(warehouse: nasr_wh, low_stock_level: 5, reorder_quantity: 15) }
  let!(:foreign_row) { foreign_product.product_warehouse_settings.create!(warehouse: foreign_wh, low_stock_level: 1, reorder_quantity: 1) }

  def user_with(*permissions, assigned: [])
    user_with_stock_permissions(business, *permissions).tap do |user|
      assigned.each { |warehouse| WarehouseAssignment.create!(user: user, warehouse: warehouse) }
    end
  end

  def policy(user, record) = described_class.new(User.find(user.id), record)

  it "is registered with its dependency on view_inventory" do
    expect(PermissionRole::PERMISSION_GROUPS[:inventory]).to include("manage_product_availability")
    expect(PermissionRole::PERMISSION_DEPENDENCIES["manage_product_availability"]).to eq(%w[view_inventory])
    expect(PermissionRole.new(business: business, name: "x", permissions: %w[manage_product_availability])).not_to be_valid
  end

  describe "a warehouse-scoped holder of manage_product_availability (assigned to Main only)" do
    let(:user) { user_with(:view_inventory, :manage_product_availability, assigned: [ central ]) }

    it "manages pairs and adds products in its own warehouse" do
      expect(policy(user, central_row).manage?).to be(true)
      expect(policy(user, central).manage?).to be(true)
    end

    it "cannot manage another warehouse of the business" do
      expect(policy(user, nasr_row).manage?).to be(false)
      expect(policy(user, nasr_wh).manage?).to be(false)
      expect(policy(user, nasr_row).show?).to be(false)
    end

    it "cannot reach another business" do
      expect(policy(user, foreign_row).manage?).to be(false)
      expect(policy(user, foreign_wh).manage?).to be(false)
    end

    it "sees only its warehouse's pairs" do
      expect(Pundit.policy_scope!(User.find(user.id), ProductWarehouseSetting)).to contain_exactly(central_row)
    end
  end

  it "manage_products or manage_inventory alone does not grant it" do
    user = user_with(:view_inventory, :manage_products, :manage_inventory)
    expect(policy(user, central_row).manage?).to be(false)
    expect(policy(user, ProductWarehouseSetting).bulk_manage?).to be(false)
    expect(policy(user, central_row).show?).to be(true)
  end

  it "an unassigned holder follows the live warehouse rule (legacy: every warehouse of the business)" do
    user = user_with(:view_inventory, :manage_product_availability)
    expect(policy(user, nasr_row).manage?).to be(true)
    expect(policy(user, foreign_row).manage?).to be(false)
  end

  it "an unassigned holder reaches none once the business is fail-closed" do
    user = user_with(:view_inventory, :manage_product_availability)
    store_warehouse_access_fail_closed!(business)
    expect(policy(user, central_row).manage?).to be(false)
    expect(Pundit.policy_scope!(User.find(user.id), ProductWarehouseSetting)).to be_empty
  end

  it "the owner manages every pair of the business, never another business's" do
    owner = create(:user, :owner, business: business)
    expect(policy(owner, nasr_row).manage?).to be(true)
    expect(policy(owner, foreign_row).manage?).to be(false)
  end

  it "refuses an unrelated record" do
    owner = create(:user, :owner, business: business)
    expect(policy(owner, product).manage?).to be(false)
  end
end
