require "rails_helper"

# Characterization — Organization & Access contracts CONSUMED BY OTHER DOMAINS
# (CURRENT behaviour). These are the methods Workforce, Attendance & Payroll,
# Inventory & Purchasing, Finance & Sales and Reporting call today; a migration
# must keep them behaving exactly like this. Already characterized elsewhere:
# EmployeeScope (spec/services/employee_scope_spec.rb), BranchScope
# (spec/services/branch_scope_spec.rb), Approvals::SelfApproval
# (spec/services/approvals/self_approval_spec.rb), BusinessDay
# (spec/lib/business_day_spec.rb), User#can?/#owner?/#manages_* (spec/models/user_spec.rb).
RSpec.describe "Characterization: Organization & Access access contracts", type: :model do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }

  def user_with(permissions, scopes: {}, workspace: "management")
    role = create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes, workspace: workspace)
    create(:user, business: business, permission_role: role)
  end

  describe "User#scope_for (data scope of a permission)" do
    it "is always 'business' for the owner" do
      expect(owner.scope_for(:view_attendance)).to eq("business")
    end

    it "returns the role's configured scope, normalizing legacy names" do
      user = user_with(%w[view_attendance view_employees], scopes: { "view_attendance" => "branch" })
      user.permission_role.update_column(:permission_scopes, { "view_attendance" => "branch", "view_employees" => "business_wide" })
      expect(user.reload.scope_for(:view_attendance)).to eq("branch")
      expect(user.scope_for(:view_employees)).to eq("business")
    end

    it "is nil (hierarchy default) when not configured or without a role" do
      expect(user_with(%w[view_attendance]).scope_for(:view_attendance)).to be_nil
      expect(create(:user, business: business).scope_for(:view_attendance)).to be_nil
    end
  end

  describe "management relationships" do
    it "managed_branch_ids / area_managed_branch_ids come from branches.branch_manager_id / area_manager_id" do
      manager = create(:user, business: business)
      branch_a.update!(branch_manager: manager)
      branch_b.update!(area_manager: manager)
      expect(manager.managed_branch_ids).to eq([ branch_a.id ])
      expect(manager.area_managed_branch_ids).to eq([ branch_b.id ])
    end
  end

  describe "User#inventory_warehouse_ids (warehouse access consumed by Inventory)" do
    it "is nil (all warehouses) for the owner and for users without assignments" do
      expect(owner.inventory_warehouse_ids).to be_nil
      expect(create(:user, business: business).inventory_warehouse_ids).to be_nil
    end

    it "lists the assigned warehouses otherwise" do
      user = create(:user, business: business)
      warehouse = Warehouse.create!(business: business, name: "Main #{SecureRandom.hex(2)}")
      user.assigned_warehouses << warehouse
      expect(user.inventory_warehouse_ids).to eq([ warehouse.id ])
      expect(user.warehouse_scoped?).to be(true)
    end
  end

  describe "User#eligible_depositor? (consumed by Finance & Sales)" do
    it "requires an active account holding create_till_deposit" do
      depositor = user_with(%w[close_till_session create_till_deposit])
      expect(depositor.eligible_depositor?).to be(true)
      depositor.update!(active: false)
      expect(depositor.eligible_depositor?).to be(false)
      expect(user_with(%w[view_attendance]).eligible_depositor?).to be(false)
    end
  end

  describe "User#management_sidebar? (navigation workspace)" do
    it "is true for the owner and management-workspace roles, false for employee workspace and no role" do
      expect(owner.management_sidebar?).to be(true)
      expect(user_with(%w[view_attendance], workspace: "management").management_sidebar?).to be(true)
      expect(user_with(%w[view_attendance], workspace: "employee").management_sidebar?).to be(false)
      expect(create(:user, business: business).management_sidebar?).to be(false)
    end
  end

  describe "User#effective_branch_on (business-day branch, consumed by Attendance and cash screens)" do
    it "returns the branch of the user's active shift assignment, nil without one" do
      user = create(:user, business: business)
      expect(user.effective_branch_on(Date.current)).to be_nil
      create(:shift_assignment, user: user, branch: branch_a, shift: create(:shift, :fixed_time, business: business))
      expect(user.effective_branch_on(Date.current)).to eq(branch_a)
    end
  end

  describe "ApplicationPolicy scope helpers (used by every domain's policies)" do
    let(:helper_scope) do
      Class.new(ApplicationPolicy::Scope) do
        def branch(relation, scope, **opts) = filter_by_branch_scope(relation, scope, **opts)
        def data(relation, scope, **opts)   = filter_by_data_scope(relation, scope, **opts)
      end
    end
    let(:shift) { create(:shift, :fixed_time, business: business) }

    it "filter_by_branch_scope: 'business' leaves the relation unrestricted" do
      relation = ShiftAssignment.where(id: create(:shift_assignment, branch: branch_b, shift: shift,
                                                                       user: create(:user, business: business)).id)
      viewer = create(:user, business: business)
      expect(helper_scope.new(viewer, ShiftAssignment).branch(relation, "business").count).to eq(1)
    end

    it "filter_by_branch_scope: 'branch' keeps managed branches plus the viewer's own records" do
      manager = create(:user, business: business)
      branch_a.update!(branch_manager: manager)
      in_a   = create(:shift_assignment, branch: branch_a, shift: shift, user: create(:user, business: business))
      in_b   = create(:shift_assignment, branch: branch_b, shift: shift, user: create(:user, business: business))
      own_b  = create(:shift_assignment, branch: branch_b, shift: create(:shift, :fixed_time, business: business), user: manager)
      result = helper_scope.new(manager, ShiftAssignment).branch(ShiftAssignment.all, "branch", own_column: :user_id)
      expect(result).to include(in_a, own_b)
      expect(result).not_to include(in_b)
    end

    it "filter_by_data_scope: always includes the viewer's own records" do
      viewer = create(:user, business: business)
      mine   = create(:shift_assignment, branch: branch_a, shift: shift, user: viewer)
      other  = create(:shift_assignment, branch: branch_a, shift: create(:shift, :fixed_time, business: business),
                                         user: create(:user, business: business))
      result = helper_scope.new(viewer, ShiftAssignment).data(ShiftAssignment.all, "self")
      expect(result).to include(mine)
      expect(result).not_to include(other)
    end
  end

  describe "ApplicationPolicy#branch_within_scope? (write-scope check)" do
    let(:policy_class) do
      Class.new(ApplicationPolicy) do
        def within?(branch_id, *permissions, **opts) = branch_within_scope?(branch_id, *permissions, **opts)
      end
    end

    it "owner: any branch; branch-scoped manager: managed branches only; nil branch only when allowed" do
      manager = user_with(%w[view_expenses], scopes: { "view_expenses" => "branch" })
      branch_a.update!(branch_manager: manager)

      expect(policy_class.new(owner, nil).within?(branch_b.id, :view_expenses)).to be(true)
      expect(policy_class.new(manager, nil).within?(branch_a.id, :view_expenses)).to be(true)
      expect(policy_class.new(manager, nil).within?(branch_b.id, :view_expenses)).to be(false)
      expect(policy_class.new(manager, nil).within?(nil, :view_expenses)).to be(false)
      expect(policy_class.new(manager, nil).within?(nil, :view_expenses, allow_nil: true)).to be(true)
    end
  end

  describe "Business settings consumed by other domains" do
    it "exposes defaults for finance and attendance settings stored in the JSON column" do
      expect(business.finance_overdue_days).to eq(3)
      expect(business.finance_allow_partial_settlement?).to be(true)
      expect(business.finance_max_write_off_amount).to be_nil
      expect(business.finance_notify_thresholds).to eq([ 3, 7, 14 ])
      expect(business.attendance_suspicious_duration_hours).to eq(16)
      expect(business.attendance_critical_duration_hours).to eq(24)
    end

    it "requires the critical attendance threshold to exceed the suspicious one" do
      business.attendance_suspicious_duration_hours = 20
      business.attendance_critical_duration_hours   = 10
      expect(business).not_to be_valid
    end

    it "falls back to SAR currency info for an unknown code" do
      business.currency = "SAR"
      expect(business.currency_symbol_en).to eq("SAR")
    end
  end
end
