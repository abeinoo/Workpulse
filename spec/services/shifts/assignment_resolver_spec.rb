require "rails_helper"

RSpec.describe Shifts::AssignmentResolver, type: :model do
  let(:business) { create(:business) }
  let(:home)     { create(:branch, business: business) }
  let(:covering) { create(:branch, business: business) }
  let(:shift)    { create(:shift, :fixed_time, business: business) }
  let(:user)     { create(:user, business: business) }

  # Scenario 1 — basic temporary coverage: date resolution across a coverage window.
  describe "temporary coverage resolution (Scenario 1)" do
    let!(:regular) do
      create(:shift_assignment, user: user, shift: shift, branch: home,
             effective_from: Date.new(2026, 1, 1), effective_to: nil)
    end
    let!(:coverage) do
      create(:shift_assignment, :temporary_coverage, user: user,
             shift: create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("15:00"),
                           end_time: Time.zone.parse("23:00")),
             branch: covering, effective_from: Date.new(2026, 8, 20), effective_to: Date.new(2026, 8, 21))
    end

    it "resolves to the covering branch on the covered dates" do
      expect(described_class.for(user: user, date: Date.new(2026, 8, 20))&.branch).to eq(covering)
      expect(described_class.for(user: user, date: Date.new(2026, 8, 21))&.branch).to eq(covering)
    end

    it "resolves back to the home branch the day after coverage ends" do
      expect(described_class.for(user: user, date: Date.new(2026, 8, 22))&.branch).to eq(home)
    end

    it "resolves to the home branch before coverage starts" do
      expect(described_class.for(user: user, date: Date.new(2026, 8, 19))&.branch).to eq(home)
    end

    it "never changes the regular assignment row" do
      expect { described_class.for(user: user, date: Date.new(2026, 8, 20)) }
        .not_to change { regular.reload.attributes }
    end
  end

  # Scenario 11 — multiple, non-contiguous coverage periods.
  describe "multiple coverage periods (Scenario 11)" do
    let(:branch_a) { create(:branch, business: business) }
    let(:branch_b) { create(:branch, business: business) }

    let!(:regular) do
      create(:shift_assignment, user: user, shift: shift, branch: home,
             effective_from: Date.new(2026, 1, 1), effective_to: nil)
    end

    before do
      create(:shift_assignment, :temporary_coverage, user: user, branch: branch_a,
             shift: create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("15:00"), end_time: Time.zone.parse("23:00")),
             effective_from: Date.new(2026, 8, 1), effective_to: Date.new(2026, 8, 5))
      create(:shift_assignment, :temporary_coverage, user: user, branch: branch_b,
             shift: create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("15:00"), end_time: Time.zone.parse("23:00")),
             effective_from: Date.new(2026, 8, 10), effective_to: Date.new(2026, 8, 12))
    end

    it "resolves each date to the correct branch" do
      expect(described_class.for(user: user, date: Date.new(2026, 8, 3))&.branch).to eq(branch_a)
      expect(described_class.for(user: user, date: Date.new(2026, 8, 7))&.branch).to eq(home)
      expect(described_class.for(user: user, date: Date.new(2026, 8, 11))&.branch).to eq(branch_b)
      expect(described_class.for(user: user, date: Date.new(2026, 8, 15))&.branch).to eq(home)
    end
  end

  # Scenario 12 — a normal employee with no temporary assignment behaves exactly as before.
  describe "employee with no temporary coverage (Scenario 12)" do
    let!(:regular) do
      create(:shift_assignment, user: user, shift: shift, branch: home,
             effective_from: 1.month.ago.to_date, effective_to: nil)
    end

    it "always resolves to the regular assignment" do
      expect(described_class.for(user: user, date: Date.current)&.branch).to eq(home)
      expect(described_class.for(user: user, date: Date.current + 10.days)&.branch).to eq(home)
    end
  end

  # Scenario 13 — an employee with no ShiftAssignment at all stays unresolved
  # (must not become accidentally attendance-enabled or branch-assigned).
  describe "employee without any shift assignment (Scenario 13)" do
    it "resolves to nil" do
      expect(described_class.for(user: user, date: Date.current)).to be_nil
    end
  end

  describe "time-aware resolution" do
    let(:morning_shift) { create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("09:00"), end_time: Time.zone.parse("13:00")) }
    let(:evening_shift) { create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("16:00"), end_time: Time.zone.parse("22:00")) }
    let(:branch_b)      { create(:branch, business: business) }

    before do
      create(:shift_assignment, user: user, shift: morning_shift, branch: home,
             effective_from: Date.new(2026, 8, 1), effective_to: Date.new(2026, 8, 10))
      create(:shift_assignment, user: user, shift: evening_shift, branch: branch_b,
             effective_from: Date.new(2026, 8, 1), effective_to: Date.new(2026, 8, 10))
    end

    it "prefers the assignment whose shift window contains the given time" do
      morning_time = Time.zone.local(2026, 8, 5, 10, 0)
      evening_time = Time.zone.local(2026, 8, 5, 18, 0)

      expect(described_class.for(user: user, date: Date.new(2026, 8, 5), time: morning_time)&.branch).to eq(home)
      expect(described_class.for(user: user, date: Date.new(2026, 8, 5), time: evening_time)&.branch).to eq(branch_b)
    end
  end

  describe ".for_many" do
    let(:user_b) { create(:user, business: business) }

    let!(:user_regular) do
      create(:shift_assignment, user: user, shift: shift, branch: home,
             effective_from: Date.new(2026, 1, 1), effective_to: nil)
    end
    let!(:user_coverage) do
      create(:shift_assignment, :temporary_coverage, user: user, branch: covering,
             shift: create(:shift, :fixed_time, business: business, start_time: Time.zone.parse("15:00"), end_time: Time.zone.parse("23:00")),
             effective_from: Date.new(2026, 8, 20), effective_to: Date.new(2026, 8, 21))
    end
    let!(:user_b_regular) do
      create(:shift_assignment, user: user_b, shift: shift, branch: home,
             effective_from: Date.new(2026, 1, 1), effective_to: nil)
    end

    it "returns the same resolution as calling .for per user" do
      date = Date.new(2026, 8, 20)
      batch = described_class.for_many(users: [ user, user_b ], date: date)

      expect(batch[user.id]).to eq(described_class.for(user: user, date: date))
      expect(batch[user_b.id]).to eq(described_class.for(user: user_b, date: date))
      expect(batch[user.id].branch).to eq(covering)
      expect(batch[user_b.id].branch).to eq(home)
    end

    it "issues the same fixed number of queries regardless of user count (no N+1)" do
      def count_queries
        queries = 0
        counter = ->(*, payload) { queries += 1 unless payload[:cached] || payload[:sql].start_with?("BEGIN", "COMMIT") }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { yield }
        queries
      end

      small_batch = [ user, user_b ]
      large_batch = small_batch + create_list(:user, 20, business: business)

      small_count = count_queries { described_class.for_many(users: small_batch, date: Date.new(2026, 8, 20)) }
      large_count = count_queries { described_class.for_many(users: large_batch, date: Date.new(2026, 8, 20)) }

      expect(large_count).to eq(small_count)
    end

    it "returns nil for a user with no active assignment" do
      branchless = create(:user, business: business)
      batch = described_class.for_many(users: [ branchless ], date: Date.current)
      expect(batch[branchless.id]).to be_nil
    end
  end
end
