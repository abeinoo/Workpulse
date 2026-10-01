require "rails_helper"

RSpec.describe Shifts::AssignmentEligibility do
  let(:business)     { create(:business, timezone: "Africa/Cairo") }
  let(:branch)       { create(:branch, business: business, name: "Shubra") }
  let(:other_branch) { create(:branch, business: business, name: "Nasr City") }
  let(:today)        { Date.new(2026, 9, 30) }

  subject(:eligibility) { described_class.new(business: business, today: today) }

  def employee
    create(:user, business: business)
  end

  # hour_based shifts keep the clock-overlap validation out of the way so an
  # employee can hold concurrent assignments where a case needs them.
  def assign(user, branch:, from: today - 30, to: nil)
    create(:shift_assignment, user: user, branch: branch,
                              shift: create(:shift, :hour_based, business: business),
                              effective_from: from, effective_to: to)
  end

  def pool
    business.users
  end

  def eligible_ids
    eligibility.eligible_users(pool).pluck(:id)
  end

  def candidate_for(user)
    eligibility.candidates(pool).find { |c| c.user.id == user.id }
  end

  it "defaults the window to ShiftAssignment::AVAILABILITY_WINDOW_DAYS" do
    expect(eligibility.window_days).to eq(ShiftAssignment::AVAILABILITY_WINDOW_DAYS)
    expect(eligibility.window_end).to eq(today + ShiftAssignment::AVAILABILITY_WINDOW_DAYS)
  end

  describe "employees who don't work shifts" do
    it "excludes the business owner even with no assignment" do
      owner = employee
      business.update!(owner: owner)
      expect(eligible_ids).not_to include(owner.id)
      expect(eligibility.eligible?(owner.id)).to be false
    end

    it "excludes a remote employee (not shift-based) with no assignment" do
      remote = create(:user, business: business, requires_shift_assignment: false)
      expect(eligible_ids).not_to include(remote.id)
    end

    it "excludes a non-shift employee even when their last assignment has ended" do
      user = create(:user, business: business, requires_shift_assignment: false)
      assign(user, branch: branch, from: today - 60, to: today - 1)
      expect(eligible_ids).not_to include(user.id)
    end

    it "excludes a non-shift employee whose assignment ends within the window" do
      user = create(:user, business: business, requires_shift_assignment: false)
      assign(user, branch: other_branch, to: today + 3)
      expect(eligibility.eligible?(user.id)).to be false
    end

    it "treats employees as shift-based by default" do
      expect(User.new.requires_shift_assignment).to be true
    end
  end

  describe "case 1: no shift assignment (e.g. newly hired)" do
    it "is available now" do
      user = employee
      expect(eligible_ids).to include(user.id)
      expect(candidate_for(user)).to be_available_now
    end
  end

  describe "case 2 / 5: previous assignment ended yesterday" do
    it "is treated as having no active assignment — available now" do
      user = employee
      assign(user, branch: other_branch, from: today - 60, to: today - 1)
      expect(candidate_for(user)).to be_available_now
    end
  end

  describe "case 3: active assignment in the current branch ending in 3 days" do
    it "is available soon" do
      user = employee
      assign(user, branch: branch, to: today + 3)
      expect(candidate_for(user)).to be_available_soon
    end
  end

  describe "case 4: active assignment in another branch ending in 3 days" do
    it "is available soon and carries the current branch and end date" do
      user = employee
      assign(user, branch: other_branch, to: today + 3)

      candidate = candidate_for(user)
      expect(candidate).to be_available_soon
      expect(candidate.branch_name).to eq("Nasr City")
      expect(candidate.ends_on).to eq(today + 3)
    end
  end

  describe "case 5: active assignment in another branch ending in 20 days" do
    it "is not eligible" do
      user = employee
      assign(user, branch: other_branch, to: today + 20)
      expect(eligible_ids).not_to include(user.id)
      expect(eligibility.eligible?(user.id)).to be false
    end
  end

  describe "case 6: active assignment in the current branch ending in 20 days" do
    it "is not eligible" do
      user = employee
      assign(user, branch: branch, to: today + 20)
      expect(eligible_ids).not_to include(user.id)
    end
  end

  describe "case 7: assignment ends today" do
    it "is eligible" do
      user = employee
      assign(user, branch: other_branch, to: today)
      expect(eligibility.eligible?(user.id)).to be true
      expect(candidate_for(user)).to be_available_soon
    end
  end

  describe "case 8: active assignment with no end date" do
    it "is not eligible (ongoing)" do
      user = employee
      assign(user, branch: other_branch, to: nil)
      expect(eligible_ids).not_to include(user.id)
      expect(eligibility.eligible?(user.id)).to be false
    end
  end

  describe "window boundaries" do
    it "includes an assignment ending tomorrow" do
      user = employee
      assign(user, branch: branch, to: today + 1)
      expect(eligibility.eligible?(user.id)).to be true
    end

    it "includes an assignment ending exactly at the end of the window" do
      user = employee
      assign(user, branch: branch, to: today + 7)
      expect(eligibility.eligible?(user.id)).to be true
    end

    it "excludes an assignment ending one day past the window" do
      user = employee
      assign(user, branch: branch, to: today + 8)
      expect(eligibility.eligible?(user.id)).to be false
    end

    it "honours a custom window" do
      user = employee
      assign(user, branch: branch, to: today + 10)
      wide = described_class.new(business: business, today: today, window_days: 14)
      expect(wide.eligible?(user.id)).to be true
    end
  end

  describe "multiple active assignments" do
    it "is blocked when any active assignment runs beyond the window" do
      user = employee
      assign(user, branch: branch,       to: today + 3)
      assign(user, branch: other_branch, to: nil)
      expect(eligibility.eligible?(user.id)).to be false
    end

    it "reports the latest end date when all end within the window" do
      user = employee
      assign(user, branch: branch,       to: today + 2)
      assign(user, branch: other_branch, to: today + 5)
      expect(candidate_for(user).ends_on).to eq(today + 5)
    end
  end

  it "ignores future-dated (upcoming) assignments — left to overlap validations" do
    user = employee
    assign(user, branch: branch, from: today + 10, to: nil)
    expect(candidate_for(user)).to be_available_now
  end

  it "lists available-now candidates before available-soon ones" do
    soon = employee
    assign(soon, branch: other_branch, to: today + 3)
    now = employee

    statuses = eligibility.candidates(pool.where(id: [ soon.id, now.id ])).map(&:status)
    expect(statuses).to eq(%i[available_now available_soon])
  end

  describe "business-local today" do
    # 23:30 UTC on Sep 30 is already Oct 1 in Cairo (UTC+3 in 2026 DST).
    it "derives today from the business timezone, not the server clock" do
      travel_to(Time.utc(2026, 9, 30, 23, 30)) do
        expect(described_class.new(business: business).today).to eq(Date.new(2026, 10, 1))
      end
    end
  end
end
