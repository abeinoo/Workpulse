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
    it "allows a permissioned user on a deposited, unreviewed DR" do
      dr = make_dr(state: "deposited")
      expect(described_class.new(manager, dr).mark_reviewed?).to be true
    end

    it "blocks a user without the permission" do
      dr = make_dr(state: "deposited")
      expect(described_class.new(no_perm, dr).mark_reviewed?).to be false
    end

    it "blocks when only closed (no deposit recorded yet)" do
      dr = make_dr(state: "closed")
      expect(described_class.new(manager, dr).mark_reviewed?).to be false
    end

    it "blocks when open" do
      dr = make_dr(state: "open")
      expect(described_class.new(manager, dr).mark_reviewed?).to be false
    end

    it "blocks when already reviewed" do
      dr = make_dr(state: "deposited", reviewed: true)
      expect(described_class.new(manager, dr).mark_reviewed?).to be false
    end
  end

  describe "#cancel_review?" do
    it "allows a permissioned user on a reviewed, deposited DR that isn't verified yet" do
      dr = make_dr(state: "deposited", reviewed: true)
      expect(described_class.new(manager, dr).cancel_review?).to be true
    end

    it "blocks when not reviewed" do
      dr = make_dr(state: "deposited", reviewed: false)
      expect(described_class.new(manager, dr).cancel_review?).to be false
    end

    it "blocks once bank verification is complete" do
      dr = make_dr(state: "verified", reviewed: true)
      dr.update_columns(verified_at: Time.current, verified_by_id: manager.id)
      expect(described_class.new(manager, dr).cancel_review?).to be false
    end
  end

  describe "#view_pos_transactions_verification?" do
    it "allows a user with the dedicated permission" do
      viewer = user_with("view_daily_reconciliation", "view_pos_transactions_verification")
      dr = make_dr
      expect(described_class.new(viewer, dr).view_pos_transactions_verification?).to be true
    end

    it "blocks a user without the permission, even with view_daily_reconciliation" do
      dr = make_dr
      expect(described_class.new(no_perm, dr).view_pos_transactions_verification?).to be false
    end

    it "blocks a user who only has review_daily_reconciliation" do
      dr = make_dr
      expect(described_class.new(manager, dr).view_pos_transactions_verification?).to be false
    end

    it "is independent of manage_pos_import — granted separately, not implied by it" do
      importer = user_with("view_daily_reconciliation", "view_pos_transactions_verification", "manage_pos_import")
      dr = make_dr
      expect(described_class.new(importer, dr).view_pos_transactions_verification?).to be true
      expect(described_class.new(importer, dr).manage_pos_import?).to be true
    end
  end
end
