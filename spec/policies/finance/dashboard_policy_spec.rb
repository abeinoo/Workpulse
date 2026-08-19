require "rails_helper"

RSpec.describe Finance::DashboardPolicy, type: :model do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  subject { described_class }

  describe "index?" do
    it "permits owner" do
      expect(subject.new(owner, :"finance/dashboard").index?).to be true
    end

    it "permits a user with view_finance_dashboard" do
      viewer = user_with("view_finance_dashboard")
      expect(subject.new(viewer, :"finance/dashboard").index?).to be true
    end

    it "denies a user with no permissions" do
      viewer = user_with
      expect(subject.new(viewer, :"finance/dashboard").index?).to be false
    end

    it "denies a user with other Finance permissions but not view_finance_dashboard" do
      viewer = user_with("view_expenses", "view_expense_reports", "view_daily_reconciliation")
      expect(subject.new(viewer, :"finance/dashboard").index?).to be false
    end
  end
end
