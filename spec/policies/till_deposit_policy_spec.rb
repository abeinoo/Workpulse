require "rails_helper"

RSpec.describe TillDepositPolicy do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:depositor) { user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit") }
  let(:override_depositor) do
    user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit", "override_review_requirement")
  end
  let(:owner) { create(:user, business: business).tap { |u| business.update!(owner: u) } }

  # Depositing happens BEFORE Branch Review under the current workflow —
  # `reviewed:` here simulates a deposit that's already been approved
  # (and therefore locked), not a precondition for depositing.
  def make_deposit(reviewed:, depositor_user:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current,
      reviewed_by: (depositor_user if reviewed), reviewed_at: (1.minute.ago if reviewed)
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: depositor_user.id)
    TillDeposit.new(daily_reconciliation: dr)
  end

  describe "#create?" do
    it "allows the depositor while the DR has not yet been reviewed (the normal order)" do
      deposit = make_deposit(reviewed: false, depositor_user: depositor)
      expect(described_class.new(depositor, deposit).create?).to be true
    end

    it "locks out the depositor once the DR has been reviewed/approved" do
      deposit = make_deposit(reviewed: true, depositor_user: depositor)
      expect(described_class.new(depositor, deposit).create?).to be false
    end

    it "allows a reviewed (locked) deposit for a user with override_review_requirement" do
      deposit = make_deposit(reviewed: true, depositor_user: override_depositor)
      expect(described_class.new(override_depositor, deposit).create?).to be true
    end

    it "allows the business owner to record a deposit even when they are not the assigned depositor" do
      deposit = make_deposit(reviewed: false, depositor_user: depositor)
      expect(described_class.new(owner, deposit).create?).to be true
    end

    it "allows the business owner even on an already-reviewed (locked) DR" do
      deposit = make_deposit(reviewed: true, depositor_user: depositor)
      expect(described_class.new(owner, deposit).create?).to be true
    end

    it "still blocks a non-owner, non-depositor user without override_review_requirement" do
      other = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")
      deposit = make_deposit(reviewed: false, depositor_user: depositor)
      expect(described_class.new(other, deposit).create?).to be false
    end
  end
end
