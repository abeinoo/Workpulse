require "rails_helper"

RSpec.describe Dashboard::Birthdays do
  let(:business) { create(:business) }
  let(:today)    { Date.new(2026, 9, 29) }
  let(:viewer)   { create(:user, business: business, date_of_birth: Date.new(1980, 9, 29)) }

  describe ".team" do
    let(:branch) { create(:branch, business: business, name: "Nasr City") }
    let!(:celebrant) do
      create(:user, business: business, first_name: "Ahmed", last_name: "Mohamed",
                    date_of_birth: Date.new(1995, 9, 29))
    end

    before do
      create(:shift_assignment, business: business, user: celebrant, branch: branch,
                                effective_from: today - 30)
    end

    it "returns birthdays from the given relation with their current branch" do
      entries = described_class.team(User.where(business: business), viewer: viewer, date: today)

      expect(entries.map(&:user)).to eq([ celebrant ])
      expect(entries.first.branch_name).to eq("Nasr City")
    end

    it "excludes the viewer (they get their own celebration instead)" do
      entries = described_class.team(User.where(business: business), viewer: viewer, date: today)
      expect(entries.map(&:user)).not_to include(viewer)
    end

    it "excludes inactive employees" do
      celebrant.update!(active: false)
      expect(described_class.team(User.where(business: business), viewer: viewer, date: today)).to be_empty
    end

    it "never widens the relation it is given" do
      entries = described_class.team(User.where(id: viewer.id), viewer: viewer, date: today)
      expect(entries).to be_empty
    end

    it "handles employees with no current branch" do
      loner = create(:user, business: business, date_of_birth: Date.new(1999, 9, 29))
      entry = described_class.team(User.where(business: business), viewer: viewer, date: today)
                             .find { |e| e.user == loner }
      expect(entry.branch_name).to be_nil
    end
  end

  describe Dashboard::Birthdays::Celebration do
    before { allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new) }

    it "is not shown until marked, then shown for that day only" do
      expect(described_class.shown?(viewer, today)).to be false

      described_class.mark_shown!(viewer, today)

      expect(described_class.shown?(viewer, today)).to be true
      expect(described_class.shown?(viewer, today.next_year)).to be false
    end

    it "is tracked per employee" do
      other = create(:user, business: business)
      described_class.mark_shown!(viewer, today)
      expect(described_class.shown?(other, today)).to be false
    end
  end
end
