require "rails_helper"

# Warehouse Architecture PR 5 (Phase 2): Inventory::WarehouseAccess — the
# Inventory implementation of OrganizationAccess::WarehouseAccessProvider.
# Live only for a business switched to fail-closed (Business#warehouse_access_fail_closed?);
# the default legacy rule is pinned by the compatibility examples at the end.
RSpec.describe Inventory::WarehouseAccess do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  let!(:central)  { business.warehouses.create!(name: "Central") } # unclassified, like warehouse #1
  let!(:shubra)   { create(:branch, business: business, name: "Shubra", branch_type: "sales") }
  let!(:bulaq)    { create(:branch, business: business, name: "Bulaq", branch_type: "sales") }
  let!(:nasr)     { create(:branch, business: business, name: "Nasr", branch_type: "sales") }
  let!(:laundry)  { create(:branch, business: business, name: "Wash", branch_type: "laundry") }
  let!(:shubra_wh) { branch_warehouse(shubra) }
  let!(:bulaq_wh)  { branch_warehouse(bulaq) }
  let!(:nasr_wh)   { branch_warehouse(nasr) }
  let!(:foreign)   { other.warehouses.create!(name: "Foreign") }

  def branch_warehouse(branch) = business.warehouses.create!(name: "#{branch.name} – المخزن", kind: "branch", branch: branch)
  def ids_for(user) = described_class.warehouse_ids_for(user)

  def inventory_user(*permissions, business: self.business)
    user_with_stock_permissions(business, :view_inventory, *permissions)
  end

  def assign(user, *warehouses) = warehouses.each { |w| WarehouseAssignment.create!(user: user, warehouse: w) }

  it "gives a business owner every warehouse of the business (nil)" do
    expect(ids_for(create(:user, :owner, business: business))).to be_nil
  end

  it "gives access_all_warehouses every warehouse of the business (nil)" do
    expect(ids_for(inventory_user(:access_all_warehouses))).to be_nil
  end

  it "never grants company-wide access implicitly — not even to manage_inventory" do
    expect(ids_for(inventory_user(:manage_inventory, :manage_stock_transfers))).to eq([])
  end

  it "fails closed: no assignment and no branch-manager link -> no warehouse" do
    expect(ids_for(inventory_user)).to eq([])
  end

  it "gives exactly the assigned warehouses" do
    user = inventory_user
    assign(user, central, bulaq_wh)

    expect(ids_for(user)).to eq([ central.id, bulaq_wh.id ].sort)
  end

  it "ignores an assignment to another business's warehouse (inconsistent data, forced past validation)" do
    user = inventory_user
    assign(user, central)
    WarehouseAssignment.new(user: user, warehouse: foreign).save!(validate: false)

    expect(ids_for(user)).to eq([ central.id ])
  end

  it "gives a sales branch manager that branch's warehouse only" do
    manager = inventory_user
    shubra.update_column(:branch_manager_id, manager.id)

    expect(ids_for(manager)).to eq([ shubra_wh.id ])
  end

  # Decision 5 (Warehouse Access, Phase 2) supersedes D3 "historical access":
  # only the CURRENT, active, sales branch gives its manager its warehouse.
  it "ends the manager's automatic access when the sales branch is deactivated" do
    manager = inventory_user
    shubra.update_columns(branch_manager_id: manager.id, active: false)

    expect(ids_for(manager)).to eq([])
  end

  it "keeps an explicit assignment to the warehouse of a deactivated branch (only the automatic rule ends)" do
    manager = inventory_user
    shubra.update_columns(branch_manager_id: manager.id, active: false)
    assign(manager, shubra_wh)

    expect(ids_for(manager)).to eq([ shubra_wh.id ])
  end

  describe "branch reclassified from sales (decision 5)" do
    it "ends the automatic access when the branch changes from sales to headquarters" do
      manager = inventory_user
      shubra.update_columns(branch_manager_id: manager.id, branch_type: "headquarters")

      expect(ids_for(manager)).to eq([])
    end

    %w[maintenance laundry warehouse other].each do |type|
      it "ends the automatic access when the branch changes from sales to #{type}" do
        manager = inventory_user
        shubra.update_columns(branch_manager_id: manager.id, branch_type: type)

        expect(ids_for(manager)).to eq([])
      end
    end

    it "gives nothing for a managed branch with no linked branch warehouse (a non-sales branch that never was sales)" do
      manager = inventory_user
      laundry.update_column(:branch_manager_id, manager.id)

      expect(ids_for(manager)).to eq([])
    end

    it "never reaches a warehouse linked to another branch" do
      manager = inventory_user
      laundry.update_column(:branch_manager_id, manager.id) # manages laundry; shubra/bulaq/nasr are someone else's

      expect(ids_for(manager)).not_to include(shubra_wh.id, bulaq_wh.id, nasr_wh.id)
    end

    it "only counts a warehouse that is a branch warehouse of the same business" do
      manager = inventory_user
      shubra.update_column(:branch_manager_id, manager.id)
      shubra_wh.update_columns(business_id: other.id) # inconsistent data, forced past every validation

      expect(ids_for(manager)).to eq([])
    end
  end

  it "gives an area manager nothing through the area-manager link alone" do
    area = inventory_user
    [ shubra, bulaq, nasr, laundry ].each { |b| b.update_column(:area_manager_id, area.id) }

    expect(ids_for(area)).to eq([])
  end

  it "never reaches another business's branch warehouse through a branch-manager link" do
    manager = inventory_user
    foreign_branch = create(:branch, business: other, branch_type: "sales")
    other.warehouses.create!(name: "Foreign branch", kind: "branch", branch: foreign_branch)
    foreign_branch.update_column(:branch_manager_id, manager.id)

    expect(ids_for(manager)).to eq([])
  end

  it "represents user 17's approved target: #1 by assignment, #4 as branch manager, not #2/#3 as area manager (D2)" do
    area_manager = inventory_user(:manage_inventory, :manage_stock_transfers)
    [ shubra, bulaq, nasr, laundry ].each { |b| b.update_column(:area_manager_id, area_manager.id) }
    nasr.update_column(:branch_manager_id, area_manager.id)

    expect(ids_for(area_manager)).to eq([ nasr_wh.id ]) # before the (not yet approved) assignment

    assign(area_manager, central)
    expect(ids_for(area_manager)).to eq([ central.id, nasr_wh.id ].sort)
    expect(ids_for(area_manager)).not_to include(shubra_wh.id, bulaq_wh.id)
  end

  it "resolves a non-owner in one query, and memoizes per instance" do
    user = inventory_user
    assign(user, central)
    user.permission_role # loaded up front: the permission check is not what is counted
    user.business

    resolver = described_class.new(user)
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      queries << payload[:sql] if payload[:sql].include?(%("warehouses"))
    end
    2.times { resolver.warehouse_ids }
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(queries.size).to eq(1)
    expect(resolver.warehouse_ids).to eq([ central.id ])
  end

  describe "compatibility — legacy mode (the default; no business switched)" do
    it "leaves User#inventory_warehouse_ids fail-open for an unassigned non-owner, while the resolver says none" do
      user = inventory_user

      expect(user.inventory_warehouse_ids).to be_nil # today: every warehouse
      expect(ids_for(user)).to eq([])               # after the (separately approved) switch: none
    end

    it "leaves User#inventory_warehouse_ids unchanged for assigned users and owners" do
      user = inventory_user
      assign(user, bulaq_wh)
      owner = create(:user, :owner, business: business)

      expect(user.inventory_warehouse_ids).to eq([ bulaq_wh.id ])
      expect(owner.inventory_warehouse_ids).to be_nil
    end

    it "does not route User#inventory_warehouse_ids through the provider" do
      expect(OrganizationAccess::WarehouseAccessProvider).not_to receive(:warehouse_ids_for)
      expect(described_class).not_to receive(:warehouse_ids_for)

      inventory_user.inventory_warehouse_ids
    end
  end
end
