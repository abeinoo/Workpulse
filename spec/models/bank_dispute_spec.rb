require "rails_helper"

RSpec.describe BankDispute do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16),
      reviewed_by: actor, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  let(:deposit) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: 300, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
  end

  def dispute_attrs(overrides = {})
    {
      till_deposit: deposit, business: business, branch: branch, opened_by: actor,
      opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
      amount: 300, bank_name: "NBE", terminal_id: "T-001"
    }.merge(overrides)
  end

  describe "validations" do
    it "is valid with the required fields" do
      expect(BankDispute.new(dispute_attrs)).to be_valid
    end

    it "requires a positive amount" do
      dispute = BankDispute.new(dispute_attrs(amount: 0))
      expect(dispute).not_to be_valid
      expect(dispute.errors[:amount]).to be_present
    end

    it "requires bank_name" do
      expect(BankDispute.new(dispute_attrs(bank_name: nil))).not_to be_valid
    end

    it "requires terminal_id" do
      expect(BankDispute.new(dispute_attrs(terminal_id: nil))).not_to be_valid
    end

    it "requires transaction_date" do
      expect(BankDispute.new(dispute_attrs(transaction_date: nil))).not_to be_valid
    end

    it "validates card_last4 is exactly 4 digits when present" do
      expect(BankDispute.new(dispute_attrs(card_last4: "12"))).not_to be_valid
      expect(BankDispute.new(dispute_attrs(card_last4: "1234"))).to be_valid
    end

    it "defaults to status new" do
      expect(BankDispute.create!(dispute_attrs).status).to eq("new")
    end
  end

  describe "#can_transition_to?" do
    it "allows the documented linear path" do
      d = BankDispute.create!(dispute_attrs)
      expect(d.can_transition_to?("submitted_to_bank")).to be true
      d.update!(status: "submitted_to_bank")
      expect(d.can_transition_to?("under_investigation")).to be true
      d.update!(status: "under_investigation")
      expect(d.can_transition_to?("refunded")).to be true
      expect(d.can_transition_to?("confirmed_successful")).to be true
      expect(d.can_transition_to?("rejected")).to be true
      d.update!(status: "refunded")
      expect(d.can_transition_to?("closed")).to be true
    end

    it "rejects skipping states" do
      d = BankDispute.create!(dispute_attrs)
      expect(d.can_transition_to?("under_investigation")).to be false
      expect(d.can_transition_to?("refunded")).to be false
      expect(d.can_transition_to?("closed")).to be false
    end

    it "rejects any transition once closed" do
      d = BankDispute.create!(dispute_attrs(status: "closed"))
      expect(d.can_transition_to?("new")).to be false
      expect(d.can_transition_to?("submitted_to_bank")).to be false
    end
  end

  describe "#resolved?" do
    it "is false for new/submitted_to_bank/under_investigation" do
      %w[new submitted_to_bank under_investigation].each do |status|
        expect(BankDispute.create!(dispute_attrs(status: status)).resolved?).to be false
      end
    end

    it "is true for refunded/confirmed_successful/rejected/closed" do
      %w[refunded confirmed_successful rejected closed].each do |status|
        expect(BankDispute.create!(dispute_attrs(status: status)).resolved?).to be true
      end
    end
  end

  describe "TillDeposit#open_bank_dispute" do
    it "is nil when there is no dispute" do
      expect(deposit.open_bank_dispute).to be_nil
    end

    it "returns the dispute while unresolved" do
      d = BankDispute.create!(dispute_attrs)
      expect(deposit.reload.open_bank_dispute).to eq(d)
    end

    it "is nil once the dispute is resolved (refunded), even before closing" do
      d = BankDispute.create!(dispute_attrs(status: "refunded"))
      expect(deposit.reload.open_bank_dispute).to be_nil
      expect(d).to be_resolved
    end
  end

  describe "anchors (missing_from_bank vs atm_deposit_failure)" do
    def atm_attrs(overrides = {})
      {
        daily_reconciliation: dr, business: business, branch: branch, opened_by: actor,
        opened_at: Time.current, transaction_date: Date.new(2026, 7, 16), kind: "atm_deposit_failure",
        amount: 300, bank_name: "NBE", terminal_id: "T-001", card_last4: "1234"
      }.merge(overrides)
    end

    it "is valid anchored only on a daily_reconciliation (no till_deposit)" do
      expect(BankDispute.new(atm_attrs)).to be_valid
    end

    it "is invalid with neither anchor" do
      d = BankDispute.new(dispute_attrs.except(:till_deposit))
      expect(d).not_to be_valid
      expect(d.errors[:base]).to be_present
    end

    it "allows both anchors to coexist (post-confirmation state)" do
      d = BankDispute.create!(atm_attrs)
      d.till_deposit = deposit
      expect(d).to be_valid
    end

    it "requires card_last4 for atm_deposit_failure but not for missing_from_bank" do
      expect(BankDispute.new(atm_attrs(card_last4: nil))).not_to be_valid
      expect(BankDispute.new(dispute_attrs(card_last4: nil))).to be_valid
    end

    it "#daily_reconciliation_for resolves via either anchor" do
      via_deposit = BankDispute.create!(dispute_attrs)
      via_dr      = BankDispute.create!(atm_attrs)

      expect(via_deposit.daily_reconciliation_for).to eq(dr)
      expect(via_dr.daily_reconciliation_for).to eq(dr)
    end
  end

  describe "DailyReconciliation#open_bank_disputes" do
    it "is empty with no disputes" do
      expect(dr.open_bank_disputes).to eq([])
    end

    it "includes a dispute anchored on an active deposit" do
      d = BankDispute.create!(dispute_attrs)
      expect(dr.open_bank_disputes).to contain_exactly(d)
    end

    it "includes a dispute anchored directly on the reconciliation (no deposit yet)" do
      d = BankDispute.create!(daily_reconciliation: dr, business: business, branch: branch, opened_by: actor,
                              opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                              kind: "atm_deposit_failure", amount: 300, bank_name: "NBE", terminal_id: "T-001",
                              card_last4: "1234")
      expect(dr.open_bank_disputes).to contain_exactly(d)
    end

    it "excludes resolved disputes of either kind" do
      BankDispute.create!(dispute_attrs(status: "closed"))
      BankDispute.create!(daily_reconciliation: dr, business: business, branch: branch, opened_by: actor,
                          opened_at: Time.current, transaction_date: Date.new(2026, 7, 16),
                          kind: "atm_deposit_failure", amount: 300, bank_name: "NBE", terminal_id: "T-001",
                          card_last4: "1234", status: "refunded")

      expect(dr.open_bank_disputes).to eq([])
    end
  end
end
