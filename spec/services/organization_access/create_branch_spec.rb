require "rails_helper"

# Warehouse Architecture — PR 3: a new sales branch gets its branch warehouse
# in the same transaction (OrganizationAccess::BranchProvisioning, implemented
# by Inventory::BranchWarehouseProvisioning); a non-sales branch gets none.
RSpec.describe OrganizationAccess::CreateBranch do
  let(:business)    { create(:business) }
  let(:other)       { create(:business) }
  let(:admin)       { user_with_stock_permissions(business, :manage_branches) }
  let(:no_rights)   { user_with_stock_permissions(business, :view_inventory) }

  def create_branch(name: "Shubra", type: "sales", actor: admin, rows: nil)
    described_class.new(actor: actor, attributes: { "name" => name, "address" => "St 1", "branch_type" => type },
                        terminal_rows: rows).call
  end

  def warehouse_audits = AuditLog.where(auditable_type: "Warehouse", action: "create")

  describe "a sales branch" do
    it "is created with exactly one branch warehouse, named by the convention, audited in the same change" do
      result = create_branch(name: "صالون جدو - شارع شبرا")

      expect(result).to be_ok
      branch = result.record
      expect(branch).to be_persisted
      warehouse = Warehouse.find_by!(branch_id: branch.id)
      expect(Warehouse.where(branch_id: branch.id).count).to eq(1)
      expect(warehouse).to have_attributes(kind: "branch", business_id: business.id, status: "active",
                                           name: "صالون جدو - شارع شبرا – المخزن")

      audit = warehouse_audits.sole
      expect(audit.auditable_id).to eq(warehouse.id)
      expect(audit.actor).to eq(admin)
      expect(audit.metadata).to include("source" => "branch_provisioning", "kind" => "branch",
                                        "branch_id" => branch.id, "business_id" => business.id)
    end

    it "keeps its POS terminals in the same change" do
      result = create_branch(rows: [ { "terminal_id" => "T-100", "label" => "Front", "active" => "1" } ])

      expect(result).to be_ok
      expect(result.record.pos_terminals.pluck(:terminal_id)).to eq([ "T-100" ])
    end

    it "is not created when its warehouse name is already taken — the branch, its terminals and nothing else roll back" do
      business.warehouses.create!(name: "Shubra – المخزن", kind: "central")

      result = nil
      expect {
        result = create_branch(rows: [ { "terminal_id" => "T-200", "label" => "Front", "active" => "1" } ])
      }.not_to change { [ Branch.count, Warehouse.count, PosTerminal.count, AuditLog.count ] }

      expect(result).not_to be_ok
      expect(result.error).to eq(:warehouse_provisioning_failed)
      expect(result.record).to be_new_record
      expect(result.record.errors[:base].sole).to eq(
        I18n.t("admin.branches.warehouse_provisioning_failed",
               reason: I18n.t("inventory.warehouses.errors.name_taken", name: "Shubra – المخزن"))
      )
    end

    it "is not created when the warehouse audit entry cannot be written" do
      fail_audit_writes!(:create)

      result = nil
      expect { result = create_branch }.not_to change { [ Branch.count, Warehouse.count ] }
      expect(result.error).to eq(:warehouse_provisioning_failed)
      expect(result.record.errors[:base].sole).to include(I18n.t("inventory.warehouses.errors.audit_failed"))
    end

    it "is not created when no provisioning handler is registered (never committed without its warehouse)" do
      allow(OrganizationAccess::BranchProvisioning).to receive(:handler)
        .and_raise(OrganizationAccess::BranchProvisioning::NotRegistered)

      expect { expect { create_branch }.to raise_error(OrganizationAccess::BranchProvisioning::NotRegistered) }
        .not_to change(Branch, :count)
    end
  end

  %w[laundry headquarters maintenance warehouse other].each do |type|
    it "creates a #{type} branch with no warehouse" do
      result = create_branch(type: type)

      expect(result).to be_ok
      expect(Warehouse.count).to eq(0)
      expect(warehouse_audits).to be_empty
    end
  end

  it "refuses an unknown branch type as a form error, creating nothing" do
    result = create_branch(type: "casino")

    expect(result).not_to be_ok
    expect(result.record.errors.of_kind?(:branch_type, :inclusion)).to be(true)
    expect([ Branch.count, Warehouse.count ]).to eq([ 0, 0 ])
  end

  it "reports model validation errors without provisioning" do
    result = create_branch(name: "")

    expect(result.error).to eq(:invalid)
    expect(result.record.errors.of_kind?(:name, :blank)).to be(true)
    expect([ Branch.count, Warehouse.count ]).to eq([ 0, 0 ])
  end

  it "refuses an actor without manage_branches" do
    result = create_branch(actor: no_rights)

    expect(result.error).to eq(:not_authorized)
    expect([ Branch.count, Warehouse.count ]).to eq([ 0, 0 ])
  end

  it "creates the branch in the actor's own business only" do
    other_admin = user_with_stock_permissions(other, :manage_branches)
    branch = create_branch(actor: other_admin).record

    expect(branch.business_id).to eq(other.id)
    expect(Warehouse.find_by!(branch_id: branch.id).business_id).to eq(other.id)
  end
end
