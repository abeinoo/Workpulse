require "rails_helper"

# Characterization (Pilot 5, M1) — CURRENT behaviour of the Organization &
# Access scopes where they touch Workforce membership. Complements (does not
# repeat) spec/services/employee_scope_spec.rb, spec/services/branch_scope_spec.rb
# and spec/characterization/organization_access/access_contracts_spec.rb:
# * BranchScope's shift-assignment path equals BranchMembership.current_branch_ids;
# * EmployeeScope membership edge cases (coverage, several branches, inactive,
#   other business, no role, owner with an explicit scope);
# * ApplicationPolicy helpers with every scope value, aliases and fallbacks.
RSpec.describe "Characterization: Organization & Access scopes over Workforce membership" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:branch_c) { create(:branch, business: business) }

  def assign(user, branch, from: 1.month.ago.to_date, to: nil)
    create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: from, effective_to: to)
  end

  def cover(user, branch) = create(:shift_assignment, :temporary_coverage, user: user, branch: branch, shift: shift)

  def user_with(permissions = [], scopes: {})
    user = create(:user, business: business)
    return user if permissions.empty?

    role = create(:permission_role, business: business, permissions: permissions, permission_scopes: scopes)
    user.update_column(:permission_role_id, role.id)
    user.reload
  end

  describe "BranchScope shift-assignment path ≡ BranchMembership.current_branch_ids" do
    let(:staff) { user_with }

    def shift_branch_ids(user, scope) = BranchScope.new(user, include_shift_assignments: true).for_scope(scope)

    it "branch scope adds exactly BranchMembership.current_branch_ids (regular, coverage, several branches)" do
      assign(staff, branch_a)
      assign(staff, branch_b)
      cover(staff, branch_c)

      expect(BranchMembership.current_branch_ids(staff)).to contain_exactly(branch_a.id, branch_b.id, branch_c.id)
      expect(shift_branch_ids(staff, "branch")).to match_array(BranchMembership.current_branch_ids(staff))
    end

    it "ignores expired, future and nil-branch assignments, like BranchMembership" do
      assign(staff, branch_a, from: 2.months.ago.to_date, to: 1.day.ago.to_date)
      assign(staff, branch_b, from: 1.day.from_now.to_date)
      assign(staff, branch_c).update_column(:branch_id, nil)

      expect(BranchMembership.current_branch_ids(staff)).to eq([])
      expect(shift_branch_ids(staff, "branch")).to eq([])
    end

    it "area scope expands each membership branch to every business branch sharing its area manager" do
      regional = user_with
      [ branch_a, branch_b ].each { |b| b.update!(area_manager: regional) }
      branch_c # different area (none)
      assign(staff, branch_a)

      expect(shift_branch_ids(staff, "area")).to contain_exactly(branch_a.id, branch_b.id)
    end

    it "area scope via a covered branch expands that branch's area too" do
      regional = user_with
      [ branch_b, branch_c ].each { |b| b.update!(area_manager: regional) }
      assign(staff, branch_a)
      cover(staff, branch_b)

      expect(shift_branch_ids(staff, "area")).to contain_exactly(branch_b.id, branch_c.id)
    end

    it "adds membership to the management-based ids and keeps them de-duplicated" do
      branch_a.update!(branch_manager: staff)
      assign(staff, branch_a)
      assign(staff, branch_b)

      expect(shift_branch_ids(staff, "branch")).to contain_exactly(branch_a.id, branch_b.id)
      expect(BranchScope.new(staff).for_scope("branch")).to eq([ branch_a.id ]) # management only by default
    end

    it "stays inside the business: area expansion never reaches another business's branches" do
      other_business = create(:business)
      regional = user_with
      branch_a.update!(area_manager: regional)
      foreign = create(:branch, business: other_business)
      foreign.update_column(:area_manager_id, regional.id) # only reachable by bypassing the OA-S7 validation
      assign(staff, branch_a)

      expect(shift_branch_ids(staff, "area")).to eq([ branch_a.id ])
    end

    it "default and self are unaffected by membership" do
      assign(staff, branch_a)

      expect(BranchScope.new(staff, include_shift_assignments: true).default_ids).to contain_exactly(branch_a.id)
      expect(shift_branch_ids(staff, "self")).to eq([])
    end
  end

  describe "EmployeeScope over membership" do
    let(:manager) { user_with }

    before { branch_a.update!(branch_manager: manager) }

    it "a branch manager sees employees by regular and by temporary-coverage assignment to the managed branch" do
      regular  = user_with.tap { |u| assign(u, branch_a) }
      covering = user_with.tap { |u| assign(u, branch_b); cover(u, branch_a) }
      other    = user_with.tap { |u| assign(u, branch_b) }

      expect(EmployeeScope.new(manager).relation).to contain_exactly(regular, covering)
      expect(EmployeeScope.new(manager).relation).not_to include(other)
    end

    it "an employee assigned to several branches is visible from each managed branch" do
      both = user_with.tap { |u| assign(u, branch_a); assign(u, branch_b) }
      other_manager = user_with
      branch_b.update!(branch_manager: other_manager)

      expect(EmployeeScope.new(manager).relation).to include(both)
      expect(EmployeeScope.new(other_manager).relation).to include(both)
    end

    it "includes inactive members (callers add .active themselves)" do
      inactive = user_with.tap { |u| assign(u, branch_a) }
      inactive.update_column(:active, false)

      expect(EmployeeScope.new(manager).for_scope("branch")).to include(inactive)
    end

    it "never returns a user of another business, even one assigned to a managed branch" do
      outsider = create(:user, business: create(:business))
      # A row written before ShiftAssignment's business guard (BUG-031): planted directly.
      create(:shift_assignment, user: outsider, branch: create(:branch, business: outsider.business),
                                shift: create(:shift, business: outsider.business), effective_from: 1.month.ago.to_date)
        .update_column(:branch_id, branch_a.id)

      expect(EmployeeScope.new(manager).relation).not_to include(outsider)
      expect(EmployeeScope.new(owner).for_scope("business")).not_to include(outsider)
    end

    it "working in a branch without managing it gives nothing (branch/area are role-based)" do
      worker = user_with.tap { |u| assign(u, branch_a) }
      user_with.tap { |u| assign(u, branch_a) }

      expect(EmployeeScope.new(worker).relation).to be_empty
      expect(EmployeeScope.new(worker).for_scope("branch")).to be_empty
      expect(EmployeeScope.new(worker).for_scope("area")).to be_empty
    end

    it "a user without a role falls back to the hierarchy for every permission list" do
      no_role = user_with
      expect(no_role.permission_role).to be_nil
      branch_b.update!(branch_manager: no_role)
      member = user_with.tap { |u| assign(u, branch_b) }

      expect(EmployeeScope.new(no_role).for_permissions(:view_employees, :manage_employees)).to contain_exactly(member)
    end

    it "for an owner, for_scope applies the named scope literally (owners get 'business' from User#scope_for, not here)" do
      member = user_with.tap { |u| assign(u, branch_a) }

      expect(EmployeeScope.new(owner).relation).to include(member, manager)
      expect(EmployeeScope.new(owner).for_scope("branch")).to be_empty
      expect(EmployeeScope.new(owner).for_scope("self")).to contain_exactly(owner)
      expect(owner.scope_for(:view_employees)).to eq("business")
    end
  end

  describe "ApplicationPolicy helpers" do
    let(:scope_host) do
      Class.new(ApplicationPolicy::Scope) do
        def resolve = scope
        public :filter_by_data_scope, :filter_by_branch_scope
      end
    end
    let(:policy_host) do
      Class.new(ApplicationPolicy) { public :branch_within_scope?, :branches_within_scope? }
    end

    let(:manager)  { user_with(%w[view_employees view_expenses], scopes: { "view_expenses" => "branch" }) }
    let!(:member)  { user_with.tap { |u| assign(u, branch_a) } }
    let!(:outside) { user_with.tap { |u| assign(u, branch_b) } }

    before { branch_a.update!(branch_manager: manager) }

    def data(scope) = scope_host.new(manager, User.where(business: business)).filter_by_data_scope(User.where(business: business), scope, user_id_column: :id)

    it "filter_by_data_scope adds the viewer to every scope value, legacy alias and unknown fallback" do
      {
        "self" => [ manager ], "branch" => [ manager, member ], "area" => [ manager ],
        "branch_only" => [ manager, member ], "self_only" => [ manager ], "nonsense" => [ manager, member ]
      }.each { |scope, expected| expect(data(scope)).to match_array(expected), scope }
      expect(data("business")).to include(manager, member, outside, owner)
    end

    it "filter_by_data_scope keeps inactive members" do
      member.update_column(:active, false)
      expect(data("branch")).to include(member)
    end

    def branch_filtered(scope)
      relation = Expense.where(business: business)
      scope_host.new(manager, relation).filter_by_branch_scope(relation, scope)
    end

    it "filter_by_branch_scope: self → own records only; default → managed branches + own; business → everything" do
      in_a  = create(:expense, business: business, branch: branch_a)
      in_b  = create(:expense, business: business, branch: branch_b)
      own_b = create(:expense, business: business, branch: branch_b, created_by: manager)

      expect(branch_filtered("self")).to contain_exactly(own_b)
      expect(branch_filtered("default")).to contain_exactly(in_a, own_b)
      expect(branch_filtered("branch_only")).to contain_exactly(in_a, own_b)
      expect(branch_filtered("business")).to contain_exactly(in_a, in_b, own_b)
    end

    it "filter_by_branch_scope ignores membership unless the host opts into shift assignments" do
      worker = user_with.tap { |u| assign(u, branch_b) }
      relation = Expense.where(business: business)
      in_b = create(:expense, business: business, branch: branch_b)

      management = scope_host.new(worker, relation).filter_by_branch_scope(relation, "branch")
      shift_host = Class.new(scope_host) { def branch_scope_includes_shift_assignments? = true }
      by_shift   = shift_host.new(worker, relation).filter_by_branch_scope(relation, "branch")

      expect(management).to be_empty
      expect(by_shift).to contain_exactly(in_b)
    end

    it "branch_within_scope? / branches_within_scope? follow the first configured scope, else the default" do
      policy = policy_host.new(manager, Expense)

      expect(policy.branch_within_scope?(branch_a.id, :view_expenses)).to be(true)
      expect(policy.branch_within_scope?(branch_b.id, :view_expenses)).to be(false)
      expect(policy.branch_within_scope?(nil, :view_expenses)).to be(false)
      expect(policy.branch_within_scope?(nil, :view_expenses, allow_nil: true)).to be(true)
      expect(policy.branches_within_scope?([ branch_a.id ], :view_expenses)).to be(true)
      expect(policy.branches_within_scope?([ branch_a.id, branch_b.id ], :view_expenses)).to be(false)
      expect(policy.branches_within_scope?([], :view_expenses)).to be(false)
      expect(policy.branch_within_scope?(branch_a.id, :unconfigured_permission)).to be(true) # default: managed
    end

    it "an owner passes every branch check, including empty and nil" do
      policy = policy_host.new(owner, Expense)

      expect(policy.branch_within_scope?(nil, :view_expenses)).to be(true)
      expect(policy.branches_within_scope?([], :view_expenses)).to be(true)
      expect(policy.branches_within_scope?([ branch_b.id ], :view_expenses)).to be(true)
    end

    it "a shift-assigned host lets membership satisfy the write-scope check" do
      worker = user_with(%w[view_towel_balances create_towel_transfers], scopes: { "create_towel_transfers" => "branch" })
      assign(worker, branch_b)
      shift_policy = Class.new(policy_host) { def branch_scope_includes_shift_assignments? = true }

      expect(policy_host.new(worker, Expense).branch_within_scope?(branch_b.id, :create_towel_transfers)).to be(false)
      expect(shift_policy.new(worker, Expense).branch_within_scope?(branch_b.id, :create_towel_transfers)).to be(true)
    end
  end
end
