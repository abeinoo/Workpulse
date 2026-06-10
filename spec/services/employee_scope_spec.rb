require "rails_helper"

RSpec.describe EmployeeScope, type: :service do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }

  let(:branch)       { create(:branch, business: business) }
  let(:other_branch) { create(:branch, business: business) }

  let(:area_manager)    { create(:user, business: business) }
  let(:branch_manager)  { create(:user, business: business) }

  let(:branch_emp)      { create(:user, business: business) }
  let(:area_emp)        { create(:user, business: business) }
  let(:unrelated_emp)   { create(:user, business: business) }

  let(:shift) { create(:shift, :fixed_time, business: business) }

  before do
    branch.update_columns(area_manager_id: area_manager.id, branch_manager_id: branch_manager.id)
    # Branch membership is shift-driven: an employee belongs to a branch while they
    # hold an active ShiftAssignment to it. No UserBranch, no manager_id.
    [ area_manager, branch_manager, branch_emp, area_emp ].each do |u|
      create(:shift_assignment, user: u, branch: branch, shift: shift)
    end
  end

  describe "#relation" do
    context "owner" do
      it "returns every non-owner user in the business" do
        result = described_class.new(owner).relation
        expect(result).to include(area_manager, branch_manager, branch_emp, unrelated_emp)
        expect(result).not_to include(owner)
      end
    end

    context "area manager" do
      it "returns employees assigned to area-managed branches" do
        result = described_class.new(area_manager).relation
        expect(result).to include(branch_emp, area_emp, branch_manager)
      end

      it "excludes employees in unmanaged branches" do
        other_emp = create(:user, business: business)
        create(:shift_assignment, user: other_emp, branch: other_branch, shift: shift)
        result = described_class.new(area_manager).relation
        expect(result).not_to include(other_emp)
      end
    end

    context "branch manager" do
      it "returns employees assigned to managed branches" do
        result = described_class.new(branch_manager).relation
        expect(result).to include(branch_emp, area_emp)
      end

      it "excludes employees in other branches" do
        other_emp = create(:user, business: business)
        create(:shift_assignment, user: other_emp, branch: other_branch, shift: shift)
        result = described_class.new(branch_manager).relation
        expect(result).not_to include(other_emp)
      end
    end

    context "plain employee (manages no branch)" do
      it "returns User.none — there is no direct-report ownership" do
        result = described_class.new(unrelated_emp).relation
        expect(result).to be_empty
      end
    end

    it "never includes the manager themselves" do
      result = described_class.new(branch_manager).relation
      expect(result).not_to include(branch_manager)
    end

    it "returns an AR relation (chainable)" do
      result = described_class.new(branch_manager).relation
      expect(result).to respond_to(:where)
      expect(result.active).to be_a(ActiveRecord::Relation)
    end
  end

  describe "#for_scope" do
    it "self returns only the user themselves" do
      result = described_class.new(branch_manager).for_scope("self")
      expect(result).to contain_exactly(branch_manager)
    end

    it "branch returns employees in managed branches" do
      result = described_class.new(branch_manager).for_scope("branch")
      expect(result).to include(branch_emp, area_emp)
      expect(result).not_to include(unrelated_emp)
    end

    it "branch returns nobody for a plain member who is NOT the branch manager" do
      # Strictly role-based: a member who merely works in the branch manages no
      # branch, so the branch scope is empty (self is added back at the policy layer).
      result = described_class.new(branch_emp).for_scope("branch")
      expect(result).to be_empty
    end

    it "area returns employees in area-managed branches" do
      result = described_class.new(area_manager).for_scope("area")
      expect(result).to include(branch_emp, area_emp, branch_manager)
      expect(result).not_to include(unrelated_emp)
    end

    it "area returns nobody for a user who is not an area manager" do
      result = described_class.new(branch_manager).for_scope("area")
      expect(result).to be_empty
    end

    it "business returns all non-self users in the business" do
      result = described_class.new(branch_manager).for_scope("business")
      expect(result).to include(branch_emp, unrelated_emp, area_manager)
      expect(result).not_to include(branch_manager)
    end

    it "resolves legacy scope names through the backward-compat aliases" do
      scope = described_class.new(branch_manager)
      expect(scope.for_scope("branch_only")).to eq(scope.for_scope("branch"))
      expect(scope.for_scope("business_wide")).to eq(scope.for_scope("business"))
    end

    it "unknown scope falls back to relation" do
      scope = described_class.new(branch_manager)
      expect(scope.for_scope("nonsense")).to eq(scope.relation)
    end
  end

  describe "#includes?" do
    it "returns true when the user is in the managed set" do
      expect(described_class.new(branch_manager).includes?(branch_emp.id)).to be true
    end

    it "returns false when the user is outside the managed set" do
      expect(described_class.new(branch_manager).includes?(unrelated_emp.id)).to be false
    end
  end

  describe "#for_permission" do
    let(:wide_role) do
      create(:permission_role, business: business,
             permissions: %w[view_attendance manage_attendance],
             permission_scopes: { "manage_attendance" => "business" })
    end
    let(:wide_mgr) { create(:user, business: business, permission_role: wide_role) }

    # A branch-scoped manager: branch_manager of their own branch, with one
    # employee assigned there.
    let(:restricted_branch) { create(:branch, business: business) }
    let(:restricted_role) do
      create(:permission_role, business: business,
             permissions: %w[view_attendance manage_attendance],
             permission_scopes: { "manage_attendance" => "branch" })
    end
    let(:restricted_mgr) { create(:user, business: business, permission_role: restricted_role) }
    let!(:restricted_report) do
      create(:user, business: business).tap do |u|
        restricted_branch.update_columns(branch_manager_id: restricted_mgr.id)
        create(:shift_assignment, user: u, branch: restricted_branch, shift: shift)
      end
    end

    it "returns ALL business employees (except self) for a business scope" do
      result = described_class.new(wide_mgr).for_permission(:manage_attendance)
      expect(result).to include(branch_emp, area_emp, unrelated_emp, restricted_report)
      expect(result).not_to include(wide_mgr)
    end

    it "limits a branch-scoped manager to employees assigned to their branch" do
      result = described_class.new(restricted_mgr).for_permission(:manage_attendance)
      expect(result).to include(restricted_report)
      expect(result).not_to include(unrelated_emp, branch_emp)
    end

    it "falls back to the hierarchy relation when no scope override is configured" do
      scope = described_class.new(branch_manager)
      expect(scope.for_permission(:manage_attendance)).to eq(scope.relation)
    end

    it "treats an owner as business-wide" do
      result = described_class.new(owner).for_permission(:manage_attendance)
      expect(result).to include(branch_emp, area_emp, unrelated_emp)
    end
  end

  describe "#for_permissions (most-specific-first precedence)" do
    def role_with(scopes)
      create(:permission_role, business: business,
             permissions: %w[view_employees view_attendance manage_attendance],
             permission_scopes: scopes)
    end

    # A plain branch member (assigned to `branch`) — relation is hierarchy-only.
    let(:regional) { create(:user, business: business) }
    before { create(:shift_assignment, user: regional, branch: branch, shift: shift) }

    it "honours business configured on the broad view_employees permission" do
      regional.update!(permission_role: role_with("view_employees" => "business"))
      result = described_class.new(regional)
                 .for_permissions(:manage_attendance, :view_attendance, :view_employees)
      expect(result).to include(branch_emp, area_emp, unrelated_emp)
    end

    it "honours business configured on the feature view permission" do
      regional.update!(permission_role: role_with("view_attendance" => "business"))
      result = described_class.new(regional)
                 .for_permissions(:manage_attendance, :view_attendance, :view_employees)
      expect(result).to include(unrelated_emp)
    end

    it "lets an explicit action-permission scope override a broader one" do
      regional.update!(permission_role: role_with(
        "view_employees"    => "business",
        "manage_attendance" => "branch"))
      result = described_class.new(regional)
                 .for_permissions(:manage_attendance, :view_attendance, :view_employees)
      # branch on the action permission wins → no unrelated employee
      expect(result).not_to include(unrelated_emp)
    end

    it "falls back to the hierarchy relation when nothing is configured" do
      scope = described_class.new(branch_manager)
      expect(scope.for_permissions(:manage_attendance, :view_attendance, :view_employees))
        .to eq(scope.relation)
    end
  end
end
