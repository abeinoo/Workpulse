require "rails_helper"

# Warehouse Architecture PR 5 (Phase 4): Inventory::WarehouseAccessReport —
# today's access (old) vs Inventory::WarehouseAccess (new), per user, IDs only,
# read-only. The rake task's READ ONLY transaction is covered in
# spec/lib/tasks/inventory_warehouse_access_report_rake_spec.rb.
RSpec.describe Inventory::WarehouseAccessReport do
  let!(:business) { create(:business) }
  let!(:other)    { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }

  let!(:central)  { business.warehouses.create!(name: "Central") } # unclassified, like warehouse #1
  let!(:shubra)   { create(:branch, business: business, name: "Shubra", branch_type: "sales") }
  let!(:bulaq)    { create(:branch, business: business, name: "Bulaq", branch_type: "sales") }
  let!(:nasr)     { create(:branch, business: business, name: "Nasr", branch_type: "sales") }
  let!(:laundry)  { create(:branch, business: business, name: "Wash", branch_type: "laundry") }
  let!(:shubra_wh) { business.warehouses.create!(name: "Shubra – المخزن", kind: "branch", branch: shubra) }
  let!(:bulaq_wh)  { business.warehouses.create!(name: "Bulaq – المخزن", kind: "branch", branch: bulaq) }
  let!(:nasr_wh)   { business.warehouses.create!(name: "Nasr – المخزن", kind: "branch", branch: nasr) }
  let!(:foreign_wh) { other.warehouses.create!(name: "Foreign") }

  def role(*permissions, type: nil)
    business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: permissions.map(&:to_s), role_type: type)
  end

  def user_in(role, active: true)
    create(:user, business: business).tap { |u| u.update_columns(permission_role_id: role.id, active: active) }
  end

  # user 17's shape: an area manager of every branch, branch manager of Nasr, inventory permissions, no assignment.
  let!(:area_manager) do
    user_in(role(:view_inventory, :manage_inventory, :manage_stock_transfers, type: "area_manager")).tap do |u|
      [ shubra, bulaq, nasr, laundry ].each { |b| b.update_column(:area_manager_id, u.id) }
      nasr.update_column(:branch_manager_id, u.id)
    end
  end
  let!(:accountant)          { user_in(role(:view_inventory, :view_inventory_reports, type: "accountant")) }
  let!(:inactive_accountant) { user_in(role(:view_inventory, type: "accountant"), active: false) }
  let!(:clerk) do
    user_in(role(:view_inventory, :manage_stock_issues)).tap { |u| WarehouseAssignment.create!(user: u, warehouse: shubra_wh) }
  end
  let!(:central_buyer)  { user_in(role(:view_inventory, :access_all_warehouses)) }
  let!(:branch_manager) { user_in(role(:view_employees, type: "branch_manager")).tap { |u| shubra.update_column(:branch_manager_id, u.id) } }
  let!(:no_inventory)   { user_in(role(:view_employees)) }

  let(:all_ids) { [ central, shubra_wh, bulaq_wh, nasr_wh ].map(&:id).sort }

  def sections = described_class.new.sections
  def row(user) = sections.flat_map(&:rows).find { |r| r.user_id == user.id }

  it "represents user 17's case: today every warehouse (fail-open), after the switch only the own branch warehouse" do
    r = row(area_manager)

    expect(r.old_ids).to eq(all_ids)
    expect(r.new_ids).to eq([ nasr_wh.id ]) # #1 needs the separately approved assignment; never #2/#3 through the area link
    expect(r.lost).to eq([ central, shubra_wh, bulaq_wh ].map(&:id).sort)
    expect(r.gained).to be_empty
    expect(r.role_type).to eq("area_manager")
    expect(r.flags).to include("FAIL_OPEN", "AREA_MANAGER", "BRANCH_MANAGER", "LOSES")
  end

  it "shows an accountant relying on fail-open losing everything, active or not" do
    expect(row(accountant)).to have_attributes(old_ids: all_ids, new_ids: [], role_type: "accountant")
    expect(row(accountant).flags).to include("ACCOUNTANT", "FAIL_OPEN", "ZERO_AFTER", "LOSES")
    expect(row(inactive_accountant).flags).to include("ACCOUNTANT", "INACTIVE_USER", "LOSES")
    expect(row(inactive_accountant).active).to be(false)
  end

  it "shows an assigned user unchanged" do
    r = row(clerk)
    expect([ r.old_ids, r.new_ids ]).to eq([ [ shubra_wh.id ], [ shubra_wh.id ] ])
    expect(r).not_to be_changed
    expect(r.flags).to include("ASSIGNED")
  end

  it "keeps the owner and an access_all_warehouses holder on every warehouse" do
    expect(row(owner)).to have_attributes(old_ids: all_ids, new_ids: all_ids, inventory_permissions: [ "(owner: all)" ])
    expect(row(central_buyer)).to have_attributes(old_ids: all_ids, new_ids: all_ids)
    expect(row(central_buyer).flags).to include("ACCESS_ALL")
  end

  it "lists a branch manager without inventory permission, gaining reach to the own branch warehouse only" do
    r = row(branch_manager)
    expect(r.new_ids).to eq([ shubra_wh.id ])
    expect(r.flags).to include("BRANCH_MANAGER", "NO_INVENTORY_PERMISSION", "LOSES")
  end

  it "never flags company-wide access as ZERO_AFTER, even for a business without warehouses" do
    empty_business = create(:business)
    empty_owner    = create(:user, :owner, business: empty_business)

    section = described_class.new(business_ids: [ empty_business.id ]).sections.sole
    expect(section.warehouse_ids).to be_empty
    row = section.rows.find { |r| r.user_id == empty_owner.id }
    expect(row.flags).to include("OWNER")
    expect(row.flags).not_to include("ZERO_AFTER")
  end

  it "summarizes users with no inventory relevance instead of listing them" do
    section = sections.find { |s| s.business_id == business.id }
    expect(section.quiet_user_ids).to include(no_inventory.id)
    expect(section.rows.map(&:user_id)).not_to include(no_inventory.id)
  end

  it "keeps businesses apart: no other business's warehouse in any list, and a forced cross-business assignment flagged" do
    WarehouseAssignment.new(user: clerk, warehouse: foreign_wh).save!(validate: false)

    business_section = sections.find { |s| s.business_id == business.id }
    expect(business_section.warehouse_ids).not_to include(foreign_wh.id)
    expect(row(clerk).new_ids).to eq([ shubra_wh.id ])          # the resolver ignores it
    expect(row(clerk).flags).to include("CROSS_BUSINESS_ASSIGNMENT")
    expect(sections.find { |s| s.business_id == other.id }.rows.map(&:business_id).uniq).to all(eq(other.id))
  end

  describe "per-business warehouse access mode" do
    def section(target) = sections.find { |s| s.business_id == target.id }

    it "reports each business's mode (legacy by default)" do
      expect(section(business).mode).to eq("legacy")
      store_warehouse_access_fail_closed!(business, true)
      expect(section(business).mode).to eq("fail_closed")
      expect(section(other).mode).to eq("legacy")
    end

    it "in a fail-closed business, old = new and nobody is flagged FAIL_OPEN — not even a company-wide user" do
      company_wide = user_in(role(:view_inventory, :access_all_warehouses))
      store_warehouse_access_fail_closed!(business, true)

      rows = section(business).rows
      expect(rows.flat_map(&:flags)).not_to include("FAIL_OPEN")
      expect(rows.reject { |r| r.old_ids == r.new_ids }).to be_empty
      expect(row(company_wide).flags).to include("ACCESS_ALL")
      expect(row(accountant).flags).to include("ACCOUNTANT", "ZERO_AFTER")
    end
  end

  it "only reads: no INSERT/UPDATE/DELETE, no audit entry, no permission or assignment change" do
    writes = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      writes << payload[:sql] if payload[:sql].match?(/\A\s*(INSERT|UPDATE|DELETE|TRUNCATE)/i)
    end
    expect { sections }.not_to change { [ AuditLog.count, WarehouseAssignment.count, Warehouse.count ] }
    ActiveSupport::Notifications.unsubscribe(subscriber)

    expect(writes).to be_empty
  end
end
