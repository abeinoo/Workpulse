require "rails_helper"

# Pilot 5 — membership contract, M2: the Organization & Access contract
# OrganizationAccess::MembershipProvider and its Workforce implementation
# Workforce::MembershipProvider (delegating to BranchMembership). EmployeeScope
# and BranchScope are routed through it in M3
# (spec/services/organization_access/membership_routing_spec.rb); membership
# semantics stay pinned by
# spec/characterization/organization_access/branch_membership_spec.rb.
RSpec.describe OrganizationAccess::MembershipProvider do
  let(:business) { create(:business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:employee) { create(:user, business: business) }

  def assign(user, branch, from: 1.month.ago.to_date, to: nil)
    create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: from, effective_to: to)
  end

  # Swaps the registered provider for one example and always restores it.
  def with_provider(provider)
    original = described_class.instance_variable_get(:@provider)
    described_class.instance_variable_set(:@provider, provider)
    yield
  ensure
    described_class.instance_variable_set(:@provider, original)
  end

  describe "registration" do
    it "has the Workforce implementation registered at boot" do
      expect(described_class.provider).to equal(Workforce::MembershipProvider)
    end

    it "rejects a provider that does not implement both operations, keeping the current one" do
      incomplete = Module.new { def self.current_branch_ids(_user) = [] }

      expect { described_class.register(incomplete) }.to raise_error(ArgumentError, /current_member_ids/)
      expect(described_class.provider).to equal(Workforce::MembershipProvider)
    end

    it "raises NotRegistered instead of resolving to no members when nothing is registered" do
      with_provider(nil) do
        expect { described_class.current_branch_ids(employee) }.to raise_error(described_class::NotRegistered)
        expect { described_class.current_member_ids([ branch_a.id ]) }.to raise_error(described_class::NotRegistered)
      end
    end
  end

  describe "dispatch" do
    let(:provider) { double("provider", current_branch_ids: :branch_ids, current_member_ids: :member_ids) }

    it "passes each operation's argument to the provider and returns its result unchanged" do
      with_provider(provider) do
        expect(described_class.current_branch_ids(employee)).to eq(:branch_ids)
        expect(described_class.current_member_ids([ 1, 2 ])).to eq(:member_ids)
      end

      expect(provider).to have_received(:current_branch_ids).with(employee)
      expect(provider).to have_received(:current_member_ids).with([ 1, 2 ])
    end

    it "propagates a provider error to the caller" do
      allow(provider).to receive(:current_member_ids).and_raise(ActiveRecord::StatementInvalid, "boom")

      with_provider(provider) { expect { described_class.current_member_ids([ 1 ]) }.to raise_error(ActiveRecord::StatementInvalid) }
    end
  end

  describe "through the Workforce implementation" do
    it "current_branch_ids preserves BranchMembership: regular, coverage and several branches; not expired / future" do
      third = create(:branch, business: business)
      assign(employee, branch_a)
      create(:shift_assignment, :temporary_coverage, user: employee, branch: branch_b, shift: shift)
      assign(employee, third, from: 2.months.ago.to_date, to: 1.day.ago.to_date)
      assign(employee, create(:branch, business: business), from: 1.day.from_now.to_date)

      ids = described_class.current_branch_ids(employee)
      expect(ids).to be_an(Array)
      expect(ids).to contain_exactly(branch_a.id, branch_b.id)
      expect(ids).to match_array(BranchMembership.current_branch_ids(employee))
    end

    it "current_member_ids returns the same chainable user_id relation, never an Array" do
      assign(employee, branch_a)

      relation = described_class.current_member_ids([ branch_a.id ])
      expect(relation).to be_a(ActiveRecord::Relation)
      expect(relation).not_to be_an(Array)
      expect(relation.model).to eq(ShiftAssignment)
      expect(relation.select_values).to eq([ :user_id ])
      expect(relation.to_sql).to eq(BranchMembership.current_member_ids([ branch_a.id ]).to_sql)
    end

    it "the relation works as an IN (subquery), as EmployeeScope uses it" do
      member   = create(:user, business: business).tap { |u| assign(u, branch_a) }
      covering = create(:user, business: business).tap do |u|
        create(:shift_assignment, :temporary_coverage, user: u, branch: branch_a, shift: shift)
      end
      create(:user, business: business).tap { |u| assign(u, branch_b) }

      relation = described_class.current_member_ids([ branch_a.id ])
      users    = User.where(User.arel_table[:id].in(relation.arel))

      expect(users.to_sql).to include("IN (SELECT \"shift_assignments\".\"user_id\"")
      expect(users).to contain_exactly(member, covering)
    end

    it "keeps the Date.current boundary unchanged" do
      assign(employee, branch_a, from: Date.new(2026, 10, 8))

      travel_to(Time.utc(2026, 10, 7, 23, 59)) { expect(described_class.current_branch_ids(employee)).to eq([]) }
      travel_to(Time.utc(2026, 10, 8, 0, 1)) do
        expect(described_class.current_branch_ids(employee)).to eq([ branch_a.id ])
        expect(User.where(id: described_class.current_member_ids([ branch_a.id ]))).to contain_exactly(employee)
      end
    end
  end

  # BUG-026 Decision 1: branch deactivation asks whether staff assignments are
  # still in effect at the branch on a given business day.
  describe "effective_assignments_at?" do
    let(:day) { Date.new(2026, 10, 15) }

    it "counts current and upcoming assignments, including one ending that day" do
      assign(employee, branch_a, from: day - 30)
      expect(described_class.effective_assignments_at?(branch_a.id, on: day)).to be(true)

      ending = create(:user, business: business)
      assign(ending, branch_b, from: day - 30, to: day)
      expect(described_class.effective_assignments_at?(branch_b.id, on: day)).to be(true)

      third = create(:branch, business: business)
      assign(create(:user, business: business), third, from: day + 5)
      expect(described_class.effective_assignments_at?(third.id, on: day)).to be(true)
    end

    it "ignores ended assignments and other branches' assignments" do
      assign(employee, branch_a, from: day - 60, to: day - 1)
      assign(create(:user, business: business), branch_b, from: day - 30)

      expect(described_class.effective_assignments_at?(branch_a.id, on: day)).to be(false)
    end

    it "decides on the day it is given, not the calendar day" do
      assign(employee, branch_a, from: day - 60, to: day - 1)

      expect(described_class.effective_assignments_at?(branch_a.id, on: day - 1)).to be(true)
      expect(described_class.effective_assignments_at?(branch_a.id, on: day)).to be(false)
    end

    it "dispatches to the registered provider with the branch and day unchanged" do
      provider = double("provider", current_branch_ids: [], current_member_ids: nil, effective_assignments_at?: :answer)
      with_provider(provider) do
        expect(described_class.effective_assignments_at?(7, on: day)).to eq(:answer)
      end
      expect(provider).to have_received(:effective_assignments_at?).with(7, on: day)
    end
  end

  it "keeps the Organization & Access contract free of Workforce names" do
    source = File.read(Rails.root.join("app/services/organization_access/membership_provider.rb"))
    code   = source.each_line.reject { |line| line.lstrip.start_with?("#") }.join

    expect(code).not_to match(/\bWorkforce::|\bShiftAssignment\b|\bBranchMembership\b|shift_assignments/)
  end
end
