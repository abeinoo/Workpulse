require "rails_helper"

RSpec.describe NotificationPolicy, type: :model do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:other)    { create(:user, business: business) }

  let(:notification) { create(:notification, user: employee) }

  subject { described_class }

  describe "index?" do
    it "permits any authenticated user" do
      expect(subject.new(employee, notification).index?).to be true
      expect(subject.new(owner, notification).index?).to be true
    end
  end

  describe "show?" do
    it "permits the notification owner" do
      expect(subject.new(employee, notification).show?).to be true
    end

    it "denies another user" do
      expect(subject.new(other, notification).show?).to be false
    end

    it "denies the owner of the business (if not the notification owner)" do
      expect(subject.new(owner, notification).show?).to be false
    end
  end

  describe "update? (mark read)" do
    it "permits the notification owner" do
      expect(subject.new(employee, notification).update?).to be true
    end

    it "denies another user" do
      expect(subject.new(other, notification).update?).to be false
    end
  end

  describe "destroy?" do
    it "permits the notification owner" do
      expect(subject.new(employee, notification).destroy?).to be true
    end

    it "denies another user" do
      expect(subject.new(other, notification).destroy?).to be false
    end
  end

  describe "Scope" do
    before do
      create(:notification, user: employee)
      create(:notification, user: employee)
      create(:notification, user: other)
    end

    it "returns only the current user's notifications" do
      scope = subject::Scope.new(employee, Notification.all).resolve
      expect(scope.pluck(:user_id).uniq).to eq([employee.id])
    end

    it "never leaks another user's notifications" do
      scope = subject::Scope.new(employee, Notification.all).resolve
      expect(scope.exists?(user_id: other.id)).to be false
    end
  end
end
