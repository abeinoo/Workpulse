require "rails_helper"

# Gradual fail-closed warehouse access (option C): User#inventory_warehouse_ids
# keeps the legacy rule unless the user's business is switched to fail-closed
# (Business#warehouse_access_fail_closed?), and then delegates to the registered
# OrganizationAccess::WarehouseAccessProvider. Settings are stored directly (update_column)
# here (test database only); in the application the one writer is the audited
# OrganizationAccess::WarehouseAccessMode.
RSpec.describe User, "#inventory_warehouse_ids by warehouse access mode" do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }

  let!(:central)       { business.warehouses.create!(name: "Main Warehouse", kind: "central") }
  let!(:shubra_branch) { create(:branch, business: business, name: "Shoubra", branch_type: "sales") }
  let!(:shubra_wh)     { business.warehouses.create!(name: "Shoubra WH", kind: "branch", branch: shubra_branch) }
  let!(:nasr_wh)       { business.warehouses.create!(name: "Nasr City WH", kind: "central") }

  def with_settings(target, settings) = store_business_settings!(target, settings)

  def fail_closed!(target = business) = with_settings(target, "warehouse_access_fail_closed" => true)

  def inventory_user(*extra, within: business)
    user_with_stock_permissions(within, :view_inventory, :manage_inventory, *extra)
  end

  def fresh(user) = User.find(user.id) # drops any cached business

  describe "legacy mode (default)" do
    it "treats an absent setting as legacy: an unassigned non-owner reaches every warehouse" do
      expect(business.settings.to_h).not_to have_key("warehouse_access_fail_closed")
      expect(business.warehouse_access_fail_closed?).to be(false)
      expect(fresh(inventory_user).inventory_warehouse_ids).to be_nil
    end

    it "keeps legacy behaviour for an explicit false" do
      with_settings(business, "warehouse_access_fail_closed" => false)
      expect(fresh(inventory_user).inventory_warehouse_ids).to be_nil
    end

    [ "true", 1, "1", "yes", {}, [] ].each do |invalid|
      it "keeps legacy behaviour for a non-boolean value (#{invalid.inspect})" do
        with_settings(business, "warehouse_access_fail_closed" => invalid)
        expect(business.reload.warehouse_access_fail_closed?).to be(false)
        expect(fresh(inventory_user).inventory_warehouse_ids).to be_nil
      end
    end

    it "does not consult the provider" do
      user = fresh(inventory_user)
      expect(OrganizationAccess::WarehouseAccessProvider).not_to receive(:warehouse_ids_for)
      user.inventory_warehouse_ids
    end

    it "still narrows an assigned user to their assignments" do
      user = inventory_user
      WarehouseAssignment.create!(user: user, warehouse: nasr_wh)
      expect(fresh(user).inventory_warehouse_ids).to eq([ nasr_wh.id ])
    end
  end

  describe "fail-closed mode" do
    before { fail_closed! }

    it "delegates to the registered provider" do
      user = fresh(inventory_user)
      expect(OrganizationAccess::WarehouseAccessProvider).to receive(:warehouse_ids_for).with(user).and_call_original
      user.inventory_warehouse_ids
    end

    it "gives an unassigned non-owner no warehouse at all ([] — never nil)" do
      expect(fresh(inventory_user).inventory_warehouse_ids).to eq([])
    end

    it "gives an unassigned accountant-type role no warehouse" do
      role = business.permission_roles.create!(name: "Accountant", role_type: "accountant",
                                                permissions: %w[view_inventory view_inventory_reports view_stock_count_reports])
      user = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
      expect(fresh(user).inventory_warehouse_ids).to eq([])
    end

    it "gives an assigned user exactly their assignments" do
      user = inventory_user
      WarehouseAssignment.create!(user: user, warehouse: nasr_wh)
      expect(fresh(user).inventory_warehouse_ids).to eq([ nasr_wh.id ])
    end

    it "follows the provider for access_all_warehouses (every warehouse, even with an assignment)" do
      user = inventory_user(:access_all_warehouses)
      WarehouseAssignment.create!(user: user, warehouse: nasr_wh)
      expect(fresh(user).inventory_warehouse_ids).to be_nil
    end

    it "follows the provider for a branch manager (their branch warehouse, plus assignments)" do
      user = inventory_user
      shubra_branch.update!(branch_manager_id: user.id)
      expect(fresh(user).inventory_warehouse_ids).to eq([ shubra_wh.id ])

      WarehouseAssignment.create!(user: user, warehouse: nasr_wh)
      expect(fresh(user).inventory_warehouse_ids).to contain_exactly(shubra_wh.id, nasr_wh.id)
    end

    it "keeps the owner on every warehouse without asking the provider" do
      owner = fresh(create(:user, :owner, business: business))
      expect(OrganizationAccess::WarehouseAccessProvider).not_to receive(:warehouse_ids_for)
      expect(owner.inventory_warehouse_ids).to be_nil
    end

    it "refuses a provider answer that is neither nil nor an Array" do
      user = fresh(inventory_user)
      allow(OrganizationAccess::WarehouseAccessProvider).to receive(:warehouse_ids_for).and_return("all")
      expect { user.inventory_warehouse_ids }.to raise_error(ArgumentError, /expected nil or an Array/)
    end
  end

  describe "independence between businesses" do
    it "switching business A leaves business B on the legacy rule" do
      fail_closed!(business)
      a_user = inventory_user
      b_user = inventory_user(within: other)

      expect(fresh(a_user).inventory_warehouse_ids).to eq([])
      expect(fresh(b_user).inventory_warehouse_ids).to be_nil
    end
  end
end
