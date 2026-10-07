require "rails_helper"

# Characterization (Pilot 5 — Organization & Access ↔ Workforce membership
# contract, M1) — CURRENT behaviour of the Workforce BranchMembership primitive
# that Organization & Access scopes consume (EmployeeScope#members_in) and that
# BranchScope duplicates for its shift-assignment path. Nothing here is the
# desired future behaviour; a later contract must keep it exactly.
#
# Membership = a ShiftAssignment active on Date.current (any assignment_kind),
# with a non-nil branch. Date.current follows the CURRENT Time.zone (the
# business timezone inside web requests, UTC elsewhere) and ignores
# business_day_start_hour — pinned as-is, not BusinessDay.current.
RSpec.describe "Characterization: BranchMembership (membership primitive)" do
  let(:business) { create(:business, timezone: "UTC", business_day_start_hour: 0) }
  let(:branch_a) { create(:branch, business: business) }
  let(:branch_b) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :hour_based, business: business) }

  def assign(user, branch, from: 1.month.ago.to_date, to: nil, **attrs)
    create(:shift_assignment, user: user, branch: branch, shift: shift, effective_from: from, effective_to: to, **attrs)
  end

  def member?(user, branch_ids) = User.where(id: BranchMembership.current_member_ids(branch_ids)).exists?(user.id)

  let(:employee) { create(:user, business: business) }

  describe ".current_branch_ids" do
    it "is the branch of a regular assignment active today" do
      assign(employee, branch_a)
      expect(BranchMembership.current_branch_ids(employee)).to eq([ branch_a.id ])
    end

    it "includes a temporary_coverage assignment alongside the regular one" do
      assign(employee, branch_a)
      create(:shift_assignment, :temporary_coverage, user: employee, branch: branch_b, shift: shift)

      expect(BranchMembership.current_branch_ids(employee)).to contain_exactly(branch_a.id, branch_b.id)
    end

    it "lists every concurrently active branch once" do
      assign(employee, branch_a)
      assign(employee, branch_b)

      expect(BranchMembership.current_branch_ids(employee)).to contain_exactly(branch_a.id, branch_b.id)
    end

    it "ignores expired and future assignments" do
      assign(employee, branch_a, from: 2.months.ago.to_date, to: 1.day.ago.to_date)
      assign(employee, branch_b, from: 1.day.from_now.to_date)

      expect(BranchMembership.current_branch_ids(employee)).to eq([])
    end

    it "counts an assignment ending today and one starting today (inclusive bounds)" do
      assign(employee, branch_a, from: 1.month.ago.to_date, to: Date.current)
      assign(employee, branch_b, from: Date.current)

      expect(BranchMembership.current_branch_ids(employee)).to contain_exactly(branch_a.id, branch_b.id)
    end

    it "strips an active assignment with a nil branch" do
      assign(employee, branch_a).update_column(:branch_id, nil)
      expect(BranchMembership.current_branch_ids(employee)).to eq([])
    end

    it "is the same for an inactive (deactivated) user" do
      assign(employee, branch_a)
      employee.update_column(:active, false)

      expect(BranchMembership.current_branch_ids(employee)).to eq([ branch_a.id ])
    end
  end

  describe ".current_member_ids" do
    it "returns a chainable ActiveRecord relation of user ids, usable as WHERE user_id IN (subquery)" do
      assign(employee, branch_a)
      ids = BranchMembership.current_member_ids([ branch_a.id ])

      expect(ids).to be_a(ActiveRecord::Relation)
      expect(ids.model).to eq(ShiftAssignment)
      expect(ids.select_values).to eq([ :user_id ])
      expect(User.where(id: ids).to_sql).to match(/"users"\."id" IN \(SELECT "shift_assignments"\."user_id" FROM "shift_assignments"/)
      expect(User.where(User.arel_table[:id].in(ids.arel)).pluck(:id)).to eq([ employee.id ])
    end

    it "includes members by regular and temporary_coverage assignment, not expired / future / other-branch ones" do
      regular  = create(:user, business: business).tap { |u| assign(u, branch_a) }
      covering = create(:user, business: business).tap do |u|
        assign(u, branch_b)
        create(:shift_assignment, :temporary_coverage, user: u, branch: branch_a, shift: shift)
      end
      expired  = create(:user, business: business).tap { |u| assign(u, branch_a, from: 2.months.ago.to_date, to: 1.day.ago.to_date) }
      future   = create(:user, business: business).tap { |u| assign(u, branch_a, from: 1.day.from_now.to_date) }
      elsewhere = create(:user, business: business).tap { |u| assign(u, branch_b) }

      members = User.where(id: BranchMembership.current_member_ids([ branch_a.id ])).pluck(:id)
      expect(members).to contain_exactly(regular.id, covering.id)
      expect(members).not_to include(expired.id, future.id, elsewhere.id)
    end

    it "includes inactive users (no active filter at this level)" do
      assign(employee, branch_a)
      employee.update_column(:active, false)

      expect(member?(employee, [ branch_a.id ])).to be(true)
    end

    it "is empty for no branch ids and for nil" do
      assign(employee, branch_a)

      expect(User.where(id: BranchMembership.current_member_ids([])).count).to eq(0)
      expect(User.where(id: BranchMembership.current_member_ids(nil)).count).to eq(0)
    end

    it "is NOT business-scoped: a user of another business assigned to this branch is returned (isolation is the caller's job)" do
      outsider = create(:user, business: create(:business))
      assign(outsider, create(:branch, business: outsider.business)).update_column(:branch_id, branch_a.id)

      expect(member?(outsider, [ branch_a.id ])).to be(true)
      expect(EmployeeScope.new(create(:user, :owner, business: business)).relation).not_to include(outsider)
    end
  end

  describe "the day boundary (Date.current, not BusinessDay.current)" do
    before { assign(employee, branch_a, from: Date.new(2026, 10, 8)) }

    it "switches at calendar midnight of the current Time.zone" do
      travel_to(Time.utc(2026, 10, 7, 23, 59)) { expect(member?(employee, [ branch_a.id ])).to be(false) }
      travel_to(Time.utc(2026, 10, 8, 0, 1))   { expect(member?(employee, [ branch_a.id ])).to be(true) }
    end

    it "ignores business_day_start_hour (the business day is still 7 Oct at 02:00)" do
      business.update!(business_day_start_hour: 6)

      travel_to(Time.utc(2026, 10, 8, 2, 0)) do
        expect(BusinessDay.current(context: business)).to eq(Date.new(2026, 10, 7))
        expect(member?(employee, [ branch_a.id ])).to be(true)
      end
    end

    it "follows Time.zone: the same instant is a different day in the business timezone (as inside web requests)" do
      travel_to(Time.utc(2026, 10, 7, 22, 0)) do
        expect(member?(employee, [ branch_a.id ])).to be(false)                                       # UTC: 7 Oct
        Time.use_zone("Asia/Riyadh") { expect(member?(employee, [ branch_a.id ])).to be(true) }       # Riyadh: 8 Oct 01:00
      end
    end
  end

  it "manager_ids (no production caller) returns the branch/area managers of the user's current branches, without the user" do
    branch_manager = create(:user, business: business)
    area_manager   = create(:user, business: business)
    branch_a.update!(branch_manager: branch_manager, area_manager: area_manager)
    assign(employee, branch_a)

    expect(BranchMembership.manager_ids(employee)).to contain_exactly(branch_manager.id, area_manager.id)
    expect(BranchMembership.manager_ids(branch_manager)).to eq([])
  end
end
