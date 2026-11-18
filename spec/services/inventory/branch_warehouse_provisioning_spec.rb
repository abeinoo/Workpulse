require "rails_helper"

# Warehouse Architecture — PR 3: the Inventory side of branch provisioning —
# Inventory::BranchWarehouseProvisioning (the contract implementation) and the
# narrow Inventory::WarehouseManager#provision_branch_warehouse behind it.
RSpec.describe Inventory::BranchWarehouseProvisioning do
  let(:business) { create(:business) }
  let(:other)    { create(:business) }
  let(:actor)    { user_with_stock_permissions(business, :manage_branches) } # no inventory permission at all
  let(:branch)   { create(:branch, business: business, name: "Shubra", branch_type: "sales") }

  def provision(target = branch, by: actor) = Branch.transaction { described_class.provision!(branch: target, actor: by) }
  def manager(by = actor) = Inventory::WarehouseManager.new(actor: by)
  def audits = AuditLog.where(auditable_type: "Warehouse", action: "create")

  it "is the registered OrganizationAccess::BranchProvisioning handler" do
    expect(OrganizationAccess::BranchProvisioning.handler).to equal(described_class)
  end

  it "creates the branch warehouse for a sales branch, attributed to the branch-changing user" do
    warehouse = provision

    expect(warehouse).to have_attributes(kind: "branch", branch_id: branch.id, business_id: business.id,
                                         name: "Shubra – المخزن", status: "active")
    expect(audits.sole).to have_attributes(actor_id: actor.id, auditable_id: warehouse.id)
    expect(audits.sole.metadata).to include("source" => "branch_provisioning")
  end

  it "is idempotent: a second call returns the same warehouse and writes no second audit entry" do
    first  = provision
    second = provision

    expect(second).to eq(first)
    expect(Warehouse.where(branch_id: branch.id).count).to eq(1)
    expect(audits.count).to eq(1)
  end

  it "never reuses a central warehouse, even one carrying the conventional name — it fails clearly" do
    central = business.warehouses.create!(name: "Shubra – المخزن", kind: "central")

    expect { provision }.to raise_error(OrganizationAccess::BranchProvisioning::Failed,
                                        I18n.t("inventory.warehouses.errors.name_taken", name: "Shubra – المخزن"))
    expect(central.reload).to have_attributes(kind: "central", branch_id: nil)
    expect(Warehouse.where(branch_id: branch.id)).to be_empty
  end

  it "treats a name differing only in case as taken" do
    business.warehouses.create!(name: "SHUBRA – المخزن", kind: "central")

    expect { provision }.to raise_error(OrganizationAccess::BranchProvisioning::Failed)
  end

  it "fails clearly on an inconsistent existing link and changes nothing" do
    warehouse = provision
    warehouse.update_columns(business_id: other.id) # an impossible state, forced past every validation

    expect { provision }.to raise_error(OrganizationAccess::BranchProvisioning::Failed,
                                        I18n.t("inventory.warehouses.errors.branch_warehouse_inconsistent"))
    expect(warehouse.reload).to have_attributes(business_id: other.id, branch_id: branch.id, kind: "branch")
    expect(Warehouse.where(branch_id: branch.id).count).to eq(1)
  end

  %w[laundry headquarters maintenance warehouse other].each do |type|
    it "refuses a #{type} branch" do
      non_sales = create(:branch, business: business, branch_type: type)

      expect { provision(non_sales) }.to raise_error(OrganizationAccess::BranchProvisioning::Failed,
                                                     I18n.t("inventory.warehouses.errors.branch_not_sales"))
      expect(Warehouse.count).to eq(0)
    end
  end

  describe "Inventory::WarehouseManager#provision_branch_warehouse (not a general creation path)" do
    it "refuses a branch of another business than the actor's" do
      foreign = create(:branch, business: other, branch_type: "sales")
      result = Branch.transaction { manager.provision_branch_warehouse(branch: foreign) }

      expect(result.code).to eq(:branch_not_found)
      expect(Warehouse.count).to eq(0)
    end

    it "refuses an unsaved branch" do
      result = Branch.transaction { manager.provision_branch_warehouse(branch: business.branches.build(branch_type: "sales")) }
      expect(result.code).to eq(:branch_not_found)
    end

    it "refuses to run outside a transaction" do
      allow(Warehouse.connection).to receive(:transaction_open?).and_return(false)

      expect(manager.provision_branch_warehouse(branch: branch).code).to eq(:provisioning_outside_transaction)
      expect(Warehouse.count).to eq(0)
    end

    it "re-reads the branch type under its own business -> branch locks, never trusting the in-memory record" do
      laundry = create(:branch, business: business, branch_type: "laundry")
      laundry.branch_type = "sales" # in memory only — the database still says laundry

      result = Branch.transaction { manager.provision_branch_warehouse(branch: laundry) }
      expect(result.code).to eq(:branch_not_sales)
      expect(Warehouse.count).to eq(0)
    end

    it "takes the business and branch row locks itself (a no-op for a caller already holding them)" do
      sqls = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| sqls << payload[:sql] }
      Branch.transaction { manager.provision_branch_warehouse(branch: branch) }
      ActiveSupport::Notifications.unsubscribe(subscriber)

      business_lock = sqls.index { |sql| sql.include?(%(FROM "businesses")) && sql.include?("FOR NO KEY UPDATE") }
      branch_lock   = sqls.index { |sql| sql.include?(%(FROM "branches")) && sql.include?("FOR NO KEY UPDATE") }
      insert        = sqls.index { |sql| sql.start_with?(%(INSERT INTO "warehouses")) }
      expect([ business_lock, branch_lock, insert ]).to all(be_present)
      expect(business_lock).to be < branch_lock # business -> branch -> warehouse
      expect(branch_lock).to be < insert
    end

    it "accepts no kind, name or business of the caller's choosing — only the branch and a known audit source" do
      params = Inventory::WarehouseManager.instance_method(:provision_branch_warehouse).parameters
      expect(params).to eq([ [ :keyreq, :branch ], [ :key, :source ] ])
    end

    it "audits as branch_provisioning by default and as branch_backfill only when asked" do
      provision
      other = create(:branch, business: business, name: "Nasr", branch_type: "sales")
      Branch.transaction { described_class.provision!(branch: other, actor: actor, source: "branch_backfill") }

      expect(audits.order(:id).map { |a| a.metadata["source"] }).to eq(%w[branch_provisioning branch_backfill])
    end

    it "refuses an unknown audit source and writes nothing" do
      result = Branch.transaction { manager.provision_branch_warehouse(branch: branch, source: "console") }

      expect(result.code).to eq(:invalid_provisioning_source)
      expect(Warehouse.count).to eq(0)
    end

    it "rolls back only its own savepoint on refusal, leaving the caller's transaction usable" do
      business.warehouses.create!(name: "Shubra – المخزن", kind: "central")

      Branch.transaction do
        expect(manager.provision_branch_warehouse(branch: branch).code).to eq(:name_taken)
        expect(Branch.where(id: branch.id).count).to eq(1) # the connection still works
      end
    end

    # Moved here from WarehouseManager#create, which no longer creates branch
    # warehouses: the branch warehouse's uniqueness guards on its only path.
    it "translates a unique-index violation (a lost race) into a domain error and keeps one warehouse" do
      first = provision
      # Simulate the race: the existence check misses the committed warehouse
      # and the model's uniqueness pre-check is skipped, so only the index refuses.
      allow(Warehouse).to receive(:find_by).and_call_original
      allow(Warehouse).to receive(:find_by).with(branch_id: branch.id).and_return(nil)
      allow_any_instance_of(Warehouse).to receive(:valid?).and_return(true)

      result = Branch.transaction { manager.provision_branch_warehouse(branch: branch) }

      expect(result.code).to eq(:branch_already_has_warehouse)
      expect(result.error).to eq(I18n.t("inventory.warehouses.errors.branch_already_has_warehouse"))
      expect(Warehouse.where(branch_id: branch.id).pluck(:id)).to eq([ first.id ])
      expect(audits.count).to eq(1)
    end

    it "is the only path that creates a branch warehouse — the ordinary creation path refuses one" do
      creator = user_with_stock_permissions(business, :view_inventory, :manage_inventory, :access_all_warehouses)
      refused = manager(creator).create(kind: "branch", name: "Shubra – المخزن", branch_id: branch.id)
      expect(refused.code).to eq(:branch_warehouse_requires_provisioning)
      expect(Warehouse.where(branch_id: branch.id)).to be_empty

      warehouse = provision
      expect(Warehouse.where(business_id: business.id, kind: "branch").pluck(:id, :branch_id)).to eq([ [ warehouse.id, branch.id ] ])
    end
  end
end
