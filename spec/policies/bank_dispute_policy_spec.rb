require "rails_helper"

RSpec.describe BankDisputePolicy do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:manager) { user_with("view_daily_reconciliation", "manage_bank_disputes") }
  let(:viewer)  { user_with("view_daily_reconciliation") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16),
      reviewed_by: manager, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: manager.id) }
  let(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: manager,
                        amount: 300, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
  end

  def dispute(status: "new")
    BankDispute.create!(till_deposit: deposit, business: business, branch: branch, opened_by: manager,
                        opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                        amount: 300, bank_name: "NBE", terminal_id: "T-001", status: status)
  end

  it "allows create for a user with manage_bank_disputes" do
    expect(described_class.new(manager, BankDispute.new).create?).to be true
  end

  it "denies create for a user without manage_bank_disputes" do
    expect(described_class.new(viewer, BankDispute.new).create?).to be false
  end

  it "allows show for view_daily_reconciliation" do
    expect(described_class.new(viewer, dispute).show?).to be true
  end

  describe "create? for an ordinary employee (no manage_bank_disputes)" do
    let(:cashier) { user_with("close_till_session", "create_till_deposit") }

    it "allows reporting an ATM problem for their own reconciliation (as the assigned depositor)" do
      till_session.update!(depositor_id: cashier.id)
      record = BankDispute.new(daily_reconciliation: dr, kind: "atm_deposit_failure")

      expect(described_class.new(cashier, record).create?).to be true
    end

    it "denies reporting for a reconciliation they are not the depositor of" do
      record = BankDispute.new(daily_reconciliation: dr, kind: "atm_deposit_failure")

      expect(described_class.new(cashier, record).create?).to be false
    end

    it "denies without create_till_deposit at all" do
      plain = user_with
      till_session.update!(depositor_id: plain.id)
      record = BankDispute.new(daily_reconciliation: dr, kind: "atm_deposit_failure")

      expect(described_class.new(plain, record).create?).to be false
    end
  end

  describe "show? for the reporting employee" do
    it "allows the employee who opened the case even without view_daily_reconciliation" do
      cashier = user_with("close_till_session", "create_till_deposit")
      record = BankDispute.create!(daily_reconciliation: dr, business: business, branch: branch,
                                   opened_by: cashier, opened_at: Time.current, transaction_date: Date.current,
                                   kind: "atm_deposit_failure", amount: 300, bank_name: "NBE", terminal_id: "T-001",
                                   card_last4: "1234")

      expect(described_class.new(cashier, record).show?).to be true
    end

    it "denies an unrelated employee with no view_daily_reconciliation" do
      other = user_with("close_till_session", "create_till_deposit")
      record = BankDispute.create!(daily_reconciliation: dr, business: business, branch: branch,
                                   opened_by: manager, opened_at: Time.current, transaction_date: Date.current,
                                   kind: "atm_deposit_failure", amount: 300, bank_name: "NBE", terminal_id: "T-001",
                                   card_last4: "1234")

      expect(described_class.new(other, record).show?).to be false
    end
  end

  describe "#update_case?" do
    it "allows manage_bank_disputes while open" do
      expect(described_class.new(manager, dispute(status: "under_investigation")).update_case?).to be true
    end

    it "denies once closed" do
      expect(described_class.new(manager, dispute(status: "closed")).update_case?).to be false
    end

    it "denies without manage_bank_disputes" do
      expect(described_class.new(viewer, dispute(status: "under_investigation")).update_case?).to be false
    end
  end

  describe "#confirm_deposit?" do
    it "allows manage_bank_disputes when confirmed_successful and no deposit linked yet" do
      d = dispute(status: "confirmed_successful")
      d.update_columns(till_deposit_id: nil)
      expect(described_class.new(manager, d).confirm_deposit?).to be true
    end

    it "denies from any other status" do
      expect(described_class.new(manager, dispute(status: "under_investigation")).confirm_deposit?).to be false
    end

    it "denies once a deposit is already linked" do
      d = dispute(status: "confirmed_successful")
      expect(described_class.new(manager, d).confirm_deposit?).to be false
    end
  end

  describe "transition gates" do
    it "allows submit_to_bank only from new, and only with the permission" do
      d = dispute(status: "new")
      expect(described_class.new(manager, d).submit_to_bank?).to be true
      expect(described_class.new(viewer, d).submit_to_bank?).to be false
    end

    it "denies submit_to_bank once already submitted" do
      d = dispute(status: "submitted_to_bank")
      expect(described_class.new(manager, d).submit_to_bank?).to be false
    end

    it "allows refund/confirm_successful/reject only from under_investigation" do
      d = dispute(status: "under_investigation")
      policy = described_class.new(manager, d)
      expect(policy.refund?).to be true
      expect(policy.confirm_successful?).to be true
      expect(policy.reject?).to be true
    end

    it "allows close only from a resolved-but-open status" do
      d = dispute(status: "refunded")
      expect(described_class.new(manager, d).close?).to be true

      d2 = dispute(status: "new")
      expect(described_class.new(manager, d2).close?).to be false
    end
  end
end
