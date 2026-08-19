require "rails_helper"

RSpec.describe TillDepositPolicy do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:depositor) { user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit") }
  let(:owner) { create(:user, business: business).tap { |u| business.update!(owner: u) } }

  def make_deposit(depositor_user:, verified: false)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: (verified ? "verified" : "closed"),
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current,
      verified_by: (depositor_user if verified), verified_at: (1.minute.ago if verified)
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: depositor_user.id)
    TillDeposit.new(daily_reconciliation: dr)
  end

  describe "#create?" do
    it "allows the depositor — no Deposit Review approval gate stands in the way" do
      deposit = make_deposit(depositor_user: depositor)
      expect(described_class.new(depositor, deposit).create?).to be true
    end

    it "does not require the removed review_daily_reconciliation permission to record a deposit" do
      # depositor never held review_daily_reconciliation/override_review_requirement —
      # both permissions were removed along with the Deposit Review stage.
      deposit = make_deposit(depositor_user: depositor)
      expect(described_class.new(depositor, deposit).create?).to be true
    end

    it "locks out deposits once the DR has been verified" do
      deposit = make_deposit(depositor_user: depositor, verified: true)
      expect(described_class.new(depositor, deposit).create?).to be false
    end

    it "allows the business owner to record a deposit even when they are not the assigned depositor" do
      deposit = make_deposit(depositor_user: depositor)
      expect(described_class.new(owner, deposit).create?).to be true
    end

    it "blocks even the business owner once the DR has been verified" do
      deposit = make_deposit(depositor_user: depositor, verified: true)
      expect(described_class.new(owner, deposit).create?).to be false
    end

    it "still blocks a non-owner, non-depositor user" do
      other = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit")
      deposit = make_deposit(depositor_user: depositor)
      expect(described_class.new(other, deposit).create?).to be false
    end
  end
end
