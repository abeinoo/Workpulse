require "rails_helper"

RSpec.describe Notification, type: :model do
  let(:user) { create(:user) }

  describe "validations" do
    it "is valid with valid attributes" do
      n = build(:notification, user: user)
      expect(n).to be_valid
    end

    it "requires title" do
      n = build(:notification, user: user, title: "")
      expect(n).not_to be_valid
    end

    it "rejects invalid event_type" do
      n = build(:notification, user: user, event_type: "unknown_event")
      expect(n).not_to be_valid
    end

    it "accepts all valid event_types" do
      Notification::EVENT_TYPES.each do |et|
        n = build(:notification, user: user, event_type: et)
        expect(n).to be_valid, "expected #{et} to be valid"
      end
    end
  end

  describe "#read? / #unread?" do
    it "is unread when read_at is nil" do
      n = build(:notification, :unread)
      expect(n.unread?).to be true
      expect(n.read?).to   be false
    end

    it "is read when read_at is set" do
      n = build(:notification, :read)
      expect(n.read?).to   be true
      expect(n.unread?).to be false
    end
  end

  describe "#mark_read!" do
    let(:notif) { create(:notification, :unread, user: user) }

    it "sets read_at" do
      expect { notif.mark_read! }.to change { notif.reload.read_at }.from(nil)
    end

    it "is idempotent" do
      notif.mark_read!
      expect { notif.mark_read! }.not_to change { notif.reload.read_at }
    end
  end

  describe ".mark_all_read_for!" do
    it "marks all unread notifications for a user" do
      create_list(:notification, 3, :unread, user: user)
      described_class.mark_all_read_for!(user)
      expect(user.notifications.unread.count).to eq(0)
    end

    it "does not affect other users" do
      other = create(:user, business: user.business)
      create(:notification, :unread, user: other)
      described_class.mark_all_read_for!(user)
      expect(other.notifications.unread.count).to eq(1)
    end
  end

  describe "scopes" do
    let!(:unread_notif) { create(:notification, :unread, user: user) }
    let!(:read_notif)   { create(:notification, :read,   user: user) }

    it ".unread returns only unread" do
      expect(described_class.unread).to include(unread_notif)
      expect(described_class.unread).not_to include(read_notif)
    end

    it ".for_user filters by user" do
      other = create(:user, business: user.business)
      other_notif = create(:notification, user: other)
      expect(described_class.for_user(user)).not_to include(other_notif)
    end
  end
end
