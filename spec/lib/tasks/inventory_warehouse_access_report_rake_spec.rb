require "rails_helper"
require "rake"

# Warehouse Architecture PR 5 (Phase 4) — inventory:warehouse_access_report is
# read-only: it runs inside a READ ONLY database transaction (any write would
# be refused by PostgreSQL), prints IDs only, and changes nothing.
#
# Non-transactional so the task's own READ ONLY transaction is a real one.
RSpec.describe "inventory:warehouse_access_report" do
  include_context "non-transactional database"

  before(:all) { Rails.application.load_tasks unless Rake::Task.task_defined?("inventory:warehouse_access_report") }

  let(:task)      { Rake::Task["inventory:warehouse_access_report"] }
  let!(:business) { create(:business, name: "Visible Co") }
  let!(:other)    { create(:business, name: "Unrelated Tenant Co") }
  let!(:owner)    { create(:user, :owner, business: business, first_name: "Owner", last_name: "Person") }
  let!(:central)  { business.warehouses.create!(name: "Central") }
  let!(:nasr)     { create(:branch, business: business, name: "Nasr", branch_type: "sales") }
  let!(:nasr_wh)  { business.warehouses.create!(name: "Nasr – المخزن", kind: "branch", branch: nasr) }
  let!(:area_manager) do
    role = business.permission_roles.create!(name: "Area", permissions: %w[view_inventory manage_inventory], role_type: "area_manager")
    create(:user, business: business, first_name: "Secret", last_name: "Name").tap do |u|
      u.update_column(:permission_role_id, role.id)
      nasr.update_columns(branch_manager_id: u.id, area_manager_id: u.id)
    end
  end
  let!(:foreign_user) { create(:user, :owner, business: other) }

  before { task.reenable }

  def run(env = {})
    stub_const("ENV", ENV.to_h.merge(env.transform_values(&:to_s)))
    output = StringIO.new
    allow($stdout).to receive(:puts) { |*lines| output.puts(*lines) }
    task.invoke
    output.string
  end

  it "prints old vs new access per user, by ID, and highlights the requested users" do
    output = run("BUSINESS_IDS" => business.id, "HIGHLIGHT_USER_IDS" => area_manager.id)

    expect(output).to include("READ ONLY", "Business ##{business.id} — warehouses [#{central.id},#{nasr_wh.id}]")
    expect(output).to include("user=#{area_manager.id}")
    expect(output).to include("old=[#{central.id},#{nasr_wh.id}] new=[#{nasr_wh.id}] lost=[#{central.id}] gained=[]")
    expect(output).to match(/Highlighted users\n\s+user=#{area_manager.id} /)
    expect(output).to include("Summary (")
  end

  it "reconciles every summary count with the detail lines, by user ID, and states the unlisted users" do
    shubra = create(:branch, business: business, name: "Shubra", branch_type: "sales")
    business.warehouses.create!(name: "Shubra – المخزن", kind: "branch", branch: shubra)
    manager_role = business.permission_roles.create!(name: "BM", permissions: %w[view_employees], role_type: "branch_manager")
    branch_manager = create(:user, business: business).tap do |u|
      u.update_column(:permission_role_id, manager_role.id)
      shubra.update_column(:branch_manager_id, u.id)
    end
    accountant_role = business.permission_roles.create!(name: "Acc", permissions: %w[view_inventory], role_type: "accountant")
    accountant = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, accountant_role.id) }
    quiet = create(:user, business: business)

    output = run("BUSINESS_IDS" => business.id)
    details = output.lines.grep(/\A  user=\d+ /).to_h { |l| [ l[/user=(\d+)/, 1].to_i, l[/flags=(\S*)/, 1].split(",") ] }
    summary = ->(label) { output[/^  #{label}=(\d+) \[([\d,]*)\]$/] && [ $1.to_i, $2.split(",").map(&:to_i) ] }
    with = ->(*flags) { details.select { |_, f| flags.all? { |flag| f.include?(flag) } }.keys.sort }

    { "lose" => with.("LOSES"), "gain" => with.("GAINS"), "zero_after" => with.("ZERO_AFTER"),
      "fail_open" => with.("FAIL_OPEN"), "accountants_losing" => with.("ACCOUNTANT", "LOSES"),
      "lose_without_inventory_permission" => with.("LOSES", "NO_INVENTORY_PERMISSION"),
      "lose_with_inventory_permission" => with.("LOSES") - with.("NO_INVENTORY_PERMISSION") }.each do |label, ids|
      expect(summary.(label)).to eq([ ids.size, ids ]), "#{label} does not match the detail lines"
    end
    expect(with.("LOSES")).to eq([ area_manager, branch_manager, accountant ].map(&:id).sort)
    expect(summary.("lose_without_inventory_permission")).to eq([ 1, [ branch_manager.id ] ])
    expect(details.keys).not_to include(quiet.id)
    expect(output).to match(/^  not listed: 1 user\(s\) with no inventory permission/)
  end

  it "exposes no names and, scoped to one business, nothing of another" do
    output = run("BUSINESS_IDS" => business.id)

    expect(output).not_to include("Secret", "Owner Person", "Visible Co", "Unrelated Tenant Co", "Central")
    expect(output).not_to include("Business ##{other.id}", "user=#{foreign_user.id} ")
  end

  it "writes nothing: no audit entry, no assignment, no permission, no warehouse" do
    snapshot = -> { [ AuditLog.count, WarehouseAssignment.count, Warehouse.count, User.order(:id).pluck(:permission_role_id) ] }
    expect { run }.not_to change(&snapshot)
  end

  it "runs inside a READ ONLY transaction — a write attempted during the report is refused by the database" do
    allow_any_instance_of(Inventory::WarehouseAccessReport).to receive(:sections).and_wrap_original do |original|
      WarehouseAssignment.create!(user: area_manager, warehouse: central) # must never succeed here
      original.call
    end

    expect { run }.to raise_error(ActiveRecord::StatementInvalid, /read-only transaction/)
    expect(WarehouseAssignment.count).to eq(0)
  end
end
