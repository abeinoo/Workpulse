require "rails_helper"

RSpec.describe DailyReconciliationPolicy do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(name: "R-#{SecureRandom.hex(3)}", permissions: perms)
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:no_perm)  { user_with("view_daily_reconciliation") }

  def make_dr(state: "closed")
    DailyReconciliation.create!(
      branch: branch, business: business, state: state,
      opened_at: 1.hour.ago, closed_at: (Time.current if state != "open"), business_date: Date.current
    )
  end

  describe "#view_sales_transactions_verification?" do
    it "allows a user with the dedicated permission" do
      viewer = user_with("view_daily_reconciliation", "view_sales_transactions_verification")
      dr = make_dr
      expect(described_class.new(viewer, dr).view_sales_transactions_verification?).to be true
    end

    it "blocks a user without the permission, even with view_daily_reconciliation" do
      dr = make_dr
      expect(described_class.new(no_perm, dr).view_sales_transactions_verification?).to be false
    end

    it "is independent of manage_sales_import — granted separately, not implied by it" do
      importer = user_with("view_daily_reconciliation", "view_sales_transactions_verification", "manage_sales_import")
      dr = make_dr
      expect(described_class.new(importer, dr).view_sales_transactions_verification?).to be true
      expect(described_class.new(importer, dr).manage_sales_import?).to be true
    end
  end

  describe "#view_pos_transaction_verification?" do
    it "requires BOTH view_sales_transactions_verification and view_pos_import" do
      both = user_with("view_daily_reconciliation", "view_sales_transactions_verification", "view_pos_import")
      dr = make_dr
      expect(described_class.new(both, dr).view_pos_transaction_verification?).to be true
    end

    it "blocks a user with only view_sales_transactions_verification" do
      sales_only = user_with("view_daily_reconciliation", "view_sales_transactions_verification")
      dr = make_dr
      expect(described_class.new(sales_only, dr).view_pos_transaction_verification?).to be false
    end

    it "blocks a user with only view_pos_import" do
      pos_only = user_with("view_daily_reconciliation", "view_pos_import")
      dr = make_dr
      expect(described_class.new(pos_only, dr).view_pos_transaction_verification?).to be false
    end

    it "blocks a user with neither permission" do
      dr = make_dr
      expect(described_class.new(no_perm, dr).view_pos_transaction_verification?).to be false
    end
  end

  describe "#transfer_deposit_responsibility?" do
    let(:manager)   { user_with("view_daily_reconciliation", "verify_daily_reconciliation") }
    let(:depositor) { user_with("close_till_session", "create_till_deposit") }

    def dr_owed(state: "closed")
      make_dr(state: state).tap do |dr|
        TillSession.create!(daily_reconciliation: dr, depositor: depositor)
        TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                  collected_amount: 500, refund_amount: 0)
      end
    end

    %w[closed deposited].each do |state|
      it "allows a verify_daily_reconciliation holder while cash is still owed (#{state})" do
        expect(described_class.new(manager, dr_owed(state: state)).transfer_deposit_responsibility?).to be true
      end
    end

    it "denies users without verify_daily_reconciliation, including the current depositor" do
      dr = dr_owed
      expect(described_class.new(no_perm, dr).transfer_deposit_responsibility?).to be false
      expect(described_class.new(depositor, dr).transfer_deposit_responsibility?).to be false
    end

    it "denies once the day is verified" do
      expect(described_class.new(manager, dr_owed(state: "verified")).transfer_deposit_responsibility?).to be false
    end

    it "denies once the day is fully deposited" do
      dr = dr_owed(state: "deposited")
      TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, amount: 500,
                          deposited_by: depositor, deposited_at: Time.current)
      expect(described_class.new(manager, dr).transfer_deposit_responsibility?).to be false
    end

    it "denies a class-level check" do
      expect(described_class.new(manager, DailyReconciliation).transfer_deposit_responsibility?).to be false
    end
  end
end
