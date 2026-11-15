require "rails_helper"

# receive_shortage_settlement_cash — the dedicated permission for the bulk
# "Receive Cash" settlement destination.
RSpec.describe "receive_shortage_settlement_cash permission" do
  let(:business) { create(:business) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms,
                                             permission_scopes: {})
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  describe "configuration" do
    it "is a grantable permission in the Daily Reconciliation group" do
      group = PermissionRole::PERMISSION_GROUPS.find { |_, perms| perms.include?("settle_remaining_deposit_balance") }
      expect(group.last).to include("receive_shortage_settlement_cash")
      expect(PermissionRole::ALL_PERMISSIONS).to include("receive_shortage_settlement_cash")
    end

    it "depends on settle_remaining_deposit_balance" do
      expect(PermissionRole::PERMISSION_DEPENDENCIES["receive_shortage_settlement_cash"])
        .to eq(%w[settle_remaining_deposit_balance])
    end

    it "is in no default role permission set" do
      PermissionRole::DEFAULT_PERMISSIONS_BY_ROLE_TYPE.each_value do |perms|
        expect(perms).not_to include("receive_shortage_settlement_cash")
      end
    end

    # EN/AR labels: covered for every registered permission by
    # spec/models/permission_role_translations_spec.rb.
  end

  describe DailyReconciliationPolicy do
    it "allows bulk_settle_cash? only with both settle and receive-cash permissions" do
      expect(described_class.new(user_with("view_daily_reconciliation", "settle_remaining_deposit_balance",
                                           "receive_shortage_settlement_cash"), DailyReconciliation).bulk_settle_cash?)
        .to be(true)
      expect(described_class.new(user_with("view_daily_reconciliation", "settle_remaining_deposit_balance"),
                                 DailyReconciliation).bulk_settle_cash?).to be(false)
      expect(described_class.new(user_with("view_daily_reconciliation"), DailyReconciliation).bulk_settle_cash?)
        .to be(false)
    end

    it "treats the business owner by the existing owner rule (all permissions), with no extra bypass" do
      owner = create(:user, :owner, business: business)
      expect(owner.can?(:receive_shortage_settlement_cash)).to be(true)
      expect(described_class.new(owner, DailyReconciliation).bulk_settle_cash?).to be(true)
    end
  end

  it "cannot be saved on a role without its dependency" do
    role = business.permission_roles.build(name: "Cash only", permissions: %w[view_daily_reconciliation
                                                                             receive_shortage_settlement_cash])
    expect(role).not_to be_valid
    expect(role.errors[:permissions].join).to include("'receive_shortage_settlement_cash' requires 'settle_remaining_deposit_balance'")
  end
end
