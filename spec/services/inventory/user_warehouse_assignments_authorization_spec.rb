require "rails_helper"

# Warehouse Access hardening, Phase 2 (A): who may grant or revoke explicit
# warehouse assignments — enforced by the assignment service itself, so no
# caller (form, console, future screen) is a bypass.
RSpec.describe Inventory::UserWarehouseAssignments, "authorization" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) } # eager: its factory saves the business
  let!(:main_wh)   { business.warehouses.create!(name: "Main") }
  let!(:second_wh) { business.warehouses.create!(name: "Second") }
  let!(:third_wh)  { business.warehouses.create!(name: "Third") }
  let(:employee)   { create(:user, business: business) }
  let(:refused)    { OrganizationAccess::UserWarehouseAccess::Refused }

  # manage_employees with business-wide scope, so the scope rule is not what
  # refuses unless a test says so.
  def administrator(*extra)
    role = business.permission_roles.create!(
      name: "Admin #{SecureRandom.hex(3)}",
      permissions: %w[view_employees manage_employees view_inventory] + extra.map(&:to_s),
      permission_scopes: { "view_employees" => "business", "manage_employees" => "business" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  def assign(ids, user: employee, by:) = described_class.assign(user: user, warehouse_ids: ids.map(&:to_s), actor: by)
  def assigned(user = employee) = WarehouseAssignment.where(user: user).order(:warehouse_id).pluck(:warehouse_id)

  describe "the manage_warehouse_access permission (1)" do
    it "lets a holder grant and revoke" do
      admin = administrator(:manage_warehouse_access)

      assign([ main_wh.id ], by: admin)
      expect(assigned).to eq([ main_wh.id ])

      assign([], by: admin)
      expect(assigned).to be_empty
    end

    it "refuses a manage_employees holder without it — nothing written, nothing audited" do
      hr = administrator

      expect { assign([ main_wh.id ], by: hr) }
        .to raise_error(refused) { |e| expect(e.reason).to eq(:not_permitted) }
        .and(not_change(AuditLog, :count))
      expect(assigned).to be_empty
    end

    it "refuses revoking without it too" do
      WarehouseAssignment.create!(user: employee, warehouse: main_wh)

      expect { assign([], by: administrator) }.to raise_error(refused)
      expect(assigned).to eq([ main_wh.id ])
    end

    it "is never needed by the business owner" do
      assign([ main_wh.id ], by: owner)
      expect(assigned).to eq([ main_wh.id ])
    end
  end

  describe "own access (2)" do
    it "refuses changing one's own assignments, even for a holder" do
      admin = administrator(:manage_warehouse_access)

      expect { assign([ main_wh.id ], user: admin, by: admin) }
        .to raise_error(refused) { |e| expect(e.reason).to eq(:own_access) }
      expect(assigned(admin)).to be_empty
    end
  end

  describe "the grantor's own reach (3)" do
    it "refuses granting a warehouse outside the grantor's reach" do
      admin = administrator(:manage_warehouse_access)
      WarehouseAssignment.create!(user: admin, warehouse: main_wh) # admin reaches Main only

      expect { assign([ main_wh.id, second_wh.id ], by: admin) }
        .to raise_error(refused) { |e| expect(e.reason).to eq(:outside_reach) }
      expect(assigned).to be_empty
    end

    it "grants within reach and leaves assignments outside the grantor's reach untouched (12)" do
      admin = administrator(:manage_warehouse_access)
      WarehouseAssignment.create!(user: admin, warehouse: main_wh)
      WarehouseAssignment.create!(user: employee, warehouse: third_wh) # unrelated, outside admin's reach

      assign([ main_wh.id ], by: admin) # Third absent from the set: NOT a request to remove it
      expect(assigned).to eq([ main_wh.id, third_wh.id ])

      assign([], by: admin)
      expect(assigned).to eq([ third_wh.id ])
    end

    it "refuses newly granting an inactive warehouse but allows removing one" do
      WarehouseAssignment.create!(user: employee, warehouse: second_wh)
      second_wh.update_column(:status, "inactive")
      main_wh.update_column(:status, "inactive")

      expect { assign([ second_wh.id, main_wh.id ], by: owner) }
        .to raise_error(refused) { |e| expect(e.reason).to eq(:inactive_warehouse) }
      expect(assigned).to eq([ second_wh.id ])

      assign([], by: owner)
      expect(assigned).to be_empty
    end

    it "keeps another business's warehouse an invalid record, as before" do
      foreign = create(:business).warehouses.create!(name: "Foreign")

      expect { assign([ foreign.id ], by: owner) }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "administrative scope (4)" do
    it "refuses changing a user the actor does not manage" do
      role = business.permission_roles.create!(name: "Self-scoped #{SecureRandom.hex(3)}",
                                               permissions: %w[view_employees manage_employees view_inventory manage_warehouse_access],
                                               permission_scopes: { "view_employees" => "self", "manage_employees" => "self" })
      admin = create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }

      expect { assign([ main_wh.id ], by: admin) }
        .to raise_error(refused) { |e| expect(e.reason).to eq(:not_in_scope) }
      expect(assigned).to be_empty
    end

    it "refuses changing the business owner's access" do
      admin = administrator(:manage_warehouse_access)

      expect { assign([ main_wh.id ], user: owner, by: admin) }.to raise_error(refused)
    end
  end

  describe "the employee form (UserPolicy)" do
    it "offers the warehouse field only with manage_warehouse_access, never on one's own record" do
      admin = administrator(:manage_warehouse_access)
      hr    = administrator

      expect(UserPolicy.new(admin, employee).permitted_attributes).to include(assigned_warehouse_ids: [])
      expect(UserPolicy.new(hr, employee).permitted_attributes).not_to include(assigned_warehouse_ids: [])
      expect(UserPolicy.new(admin, admin).permitted_attributes).not_to include(assigned_warehouse_ids: [])
    end
  end

  describe "#revoke_branch_warehouse" do
    let(:branch)    { create(:branch, business: business, branch_type: "sales") }
    let!(:branch_wh) { business.warehouses.create!(name: "Branch WH", kind: "branch", branch: branch) }

    it "removes only the branch-warehouse assignment, audited, and reports it" do
      WarehouseAssignment.create!(user: employee, warehouse: branch_wh)
      WarehouseAssignment.create!(user: employee, warehouse: main_wh)

      revoked = described_class.revoke_branch_warehouse(user_id: employee.id, branch_id: branch.id, actor: owner)

      expect(revoked).to eq(user_id: employee.id, warehouse_id: branch_wh.id)
      expect(assigned).to eq([ main_wh.id ])
      expect(AuditLog.where(auditable_type: "WarehouseAssignment", action: "destroy").last.actor_id).to eq(owner.id)
    end

    it "returns nil when there is nothing to revoke" do
      expect(described_class.revoke_branch_warehouse(user_id: employee.id, branch_id: branch.id, actor: owner)).to be_nil
    end
  end
end
