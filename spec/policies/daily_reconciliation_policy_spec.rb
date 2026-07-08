require "rails_helper"

RSpec.describe DailyReconciliationPolicy do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:manager)  { user_with("view_daily_reconciliation", "review_daily_reconciliation") }
  let(:no_perm)  { user_with("view_daily_reconciliation") }

  def make_dr(state: "closed", reviewed: false)
    DailyReconciliation.create!(
      branch: branch, business: business, state: state,
      opened_at: 1.hour.ago, closed_at: (Time.current if state != "open"), business_date: Date.current,
      reviewed_by: (manager if reviewed), reviewed_at: (1.minute.ago if reviewed)
    )
  end

  describe "#mark_reviewed?" do
    it "allows a permissioned user on a closed, unreviewed DR" do
      dr = make_dr
      expect(described_class.new(manager, dr).mark_reviewed?).to be true
    end

    it "blocks a user without the permission" do
      dr = make_dr
      expect(described_class.new(no_perm, dr).mark_reviewed?).to be false
    end

    it "blocks when not closed" do
      dr = make_dr(state: "open")
      expect(described_class.new(manager, dr).mark_reviewed?).to be false
    end

    it "blocks when already reviewed" do
      dr = make_dr(reviewed: true)
      expect(described_class.new(manager, dr).mark_reviewed?).to be false
    end
  end

  describe "#cancel_review?" do
    it "allows a permissioned user on a reviewed DR with no deposits" do
      dr = make_dr(reviewed: true)
      expect(described_class.new(manager, dr).cancel_review?).to be true
    end

    it "blocks when not reviewed" do
      dr = make_dr(reviewed: false)
      expect(described_class.new(manager, dr).cancel_review?).to be false
    end

    it "blocks once a deposit exists" do
      dr = make_dr(reviewed: true)
      TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id)
      dr.till_deposits.create!(payment_method: cash_pm, deposited_by: manager, amount: 100, deposited_at: Time.current)

      expect(described_class.new(manager, dr).cancel_review?).to be false
    end
  end
end
