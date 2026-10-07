require "rails_helper"

# Pilot 5 — membership contract, M3: EmployeeScope and BranchScope read branch
# membership only through OrganizationAccess::MembershipProvider. A planted
# provider proves the routing (results follow the provider, not shift
# assignments); behaviour stays pinned by the M1 characterization in
# spec/characterization/organization_access/*membership*_spec.rb.
RSpec.describe "Organization & Access scopes route membership through the contract" do
  let(:business) { create(:business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let!(:branch_a) { create(:branch, business: business) }
  let!(:branch_b) { create(:branch, business: business) }
  let!(:branch_c) { create(:branch, business: business) }
  let(:manager)  { create(:user, business: business) }
  let(:staff)    { create(:user, business: business) }
  let(:assigned) { create(:user, business: business) }
  let(:planted)  { create(:user, business: business) } # holds no shift assignment at all

  def assign(user, branch) = create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: 1.month.ago.to_date)

  # Swaps the registered provider for one example and always restores it.
  def with_provider(provider)
    original = OrganizationAccess::MembershipProvider.instance_variable_get(:@provider)
    OrganizationAccess::MembershipProvider.instance_variable_set(:@provider, provider)
    yield
  ensure
    OrganizationAccess::MembershipProvider.instance_variable_set(:@provider, original)
  end

  def provider_returning(member_ids: User.none.select(:id), branch_ids: [])
    double("membership provider", current_member_ids: member_ids, current_branch_ids: branch_ids)
  end

  before do
    branch_a.update!(branch_manager: manager)
    assign(assigned, branch_a)
  end

  describe "EmployeeScope" do
    it "takes its members from the contract, not from shift assignments" do
      provider = provider_returning(member_ids: User.where(id: planted.id).select(:id))

      with_provider(provider) do
        expect(EmployeeScope.new(manager).relation).to contain_exactly(planted)
        expect(EmployeeScope.new(manager).for_scope("branch")).to contain_exactly(planted)
      end
      expect(provider).to have_received(:current_member_ids).with([ branch_a.id ]).twice
    end

    it "keeps business isolation on top of the contract's ids (EmployeeScope.base)" do
      outsider = create(:user, business: create(:business))
      provider = provider_returning(member_ids: User.where(id: [ planted.id, outsider.id ]).select(:id))

      with_provider(provider) { expect(EmployeeScope.new(manager).relation).to contain_exactly(planted) }
    end

    it "asks nothing of the contract for a business scope or with no branches to resolve" do
      provider = provider_returning

      with_provider(provider) do
        EmployeeScope.new(manager).for_scope("business").to_a
        EmployeeScope.new(staff).relation.to_a # manages nothing
      end
      expect(provider).not_to have_received(:current_member_ids)
    end

    it "with the registered Workforce provider: same members and the same IN (subquery) SQL as before" do
      relation = EmployeeScope.new(manager).relation

      expect(relation).to contain_exactly(assigned)
      expect(relation.to_sql).to include('IN (SELECT "shift_assignments"."user_id" FROM "shift_assignments"')
    end
  end

  describe "BranchScope" do
    def shift_scope(scope) = BranchScope.new(staff, include_shift_assignments: true).for_scope(scope)

    it "takes the user's membership branches from the contract when include_shift_assignments is on" do
      assign(staff, branch_a)
      provider = provider_returning(branch_ids: [ branch_c.id ])

      with_provider(provider) { expect(shift_scope("branch")).to eq([ branch_c.id ]) }
      expect(provider).to have_received(:current_branch_ids).with(staff)
    end

    it "expands area scope from the contract's branches" do
      regional = create(:user, business: business)
      [ branch_b, branch_c ].each { |b| b.update!(area_manager: regional) }
      provider = provider_returning(branch_ids: [ branch_c.id ])

      with_provider(provider) { expect(shift_scope("area")).to contain_exactly(branch_b.id, branch_c.id) }
    end

    it "does not consult the contract when include_shift_assignments is off, or for self / business" do
      provider = provider_returning(branch_ids: [ branch_c.id ])

      with_provider(provider) do
        expect(BranchScope.new(staff).for_scope("branch")).to eq([])
        expect(shift_scope("self")).to eq([])
        expect(shift_scope("business")).to contain_exactly(branch_a.id, branch_b.id, branch_c.id)
      end
      expect(provider).not_to have_received(:current_branch_ids)
    end

    it "with the registered Workforce provider: the same ids as the Workforce membership" do
      assign(staff, branch_a)
      create(:shift_assignment, :temporary_coverage, user: staff, branch: branch_b, shift: shift)

      expect(shift_scope("branch")).to match_array(Workforce::MembershipProvider.current_branch_ids(staff))
      expect(shift_scope("branch")).to contain_exactly(branch_a.id, branch_b.id)
    end
  end

  it "Organization & Access scope code names neither BranchMembership nor ShiftAssignment" do
    %w[app/services/employee_scope.rb app/services/branch_scope.rb].each do |path|
      code = File.read(Rails.root.join(path)).each_line.reject { |line| line.lstrip.start_with?("#") }.join

      expect(code).not_to match(/\bBranchMembership\b|\bShiftAssignment\b|\.shift_assignments\b/), path
      expect(code).to include("OrganizationAccess::MembershipProvider."), path
    end
  end
end
