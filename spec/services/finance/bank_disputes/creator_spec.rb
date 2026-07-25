require "rails_helper"

RSpec.describe Finance::BankDisputes::Creator do
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

  let(:params) do
    { transaction_date: Date.new(2026, 7, 16), transaction_time: "14:00", amount: 300,
      bank_name: "NBE", terminal_id: "T-001", merchant_id: "M-1", card_last4: "1234",
      reference_number: "REF1", stan: "STAN1", authorization_code: "AUTH1", notes: "POS deducted, deposit missing" }
  end

  describe "missing_from_bank (anchored on a TillDeposit)" do
    it "creates a new dispute in status new, opened by the actor" do
      result = described_class.new(actor: actor, till_deposit_id: deposit.id, params: params).call

      expect(result.ok?).to be true
      expect(result.dispute).to be_persisted
      expect(result.dispute.status).to eq("new")
      expect(result.dispute.kind).to eq("missing_from_bank")
      expect(result.dispute.opened_by).to eq(actor)
      expect(result.dispute.business).to eq(business)
      expect(result.dispute.branch).to eq(branch)
      expect(result.dispute.till_deposit).to eq(deposit)
      expect(result.dispute.daily_reconciliation).to be_nil
      expect(result.dispute.amount).to eq(300)
    end

    it "writes an audit log entry with action 'opened'" do
      result = described_class.new(actor: actor, till_deposit_id: deposit.id, params: params).call

      log = AuditLog.for_auditable(result.dispute).first
      expect(log.action).to eq("opened")
      expect(log.actor).to eq(actor)
    end

    it "fails when required fields are missing" do
      result = described_class.new(actor: actor, till_deposit_id: deposit.id, params: params.except(:bank_name)).call

      expect(result.ok?).to be false
      expect(result.error).to be_present
    end

    it "only finds deposits within the actor's business" do
      other_business = create(:business)
      other_actor = create(:user, business: other_business)

      expect {
        described_class.new(actor: other_actor, till_deposit_id: deposit.id, params: params).call
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "atm_deposit_failure (anchored directly on a DailyReconciliation)" do
    let(:atm_params) { params.merge(card_last4: "1234") }

    it "creates a dispute with no TillDeposit and no RemainingDepositBalance" do
      result = described_class.new(actor: actor, daily_reconciliation_id: dr.id, params: atm_params).call

      expect(result.ok?).to be true
      expect(result.dispute.kind).to eq("atm_deposit_failure")
      expect(result.dispute.till_deposit).to be_nil
      expect(result.dispute.daily_reconciliation).to eq(dr)
      expect(TillDeposit.count).to eq(0)
      expect(RemainingDepositBalance.count).to eq(0)
      expect(dr.reload.total_deposited).to eq(0)
    end

    it "writes an audit log entry with action 'reported'" do
      result = described_class.new(actor: actor, daily_reconciliation_id: dr.id, params: atm_params).call

      log = AuditLog.for_auditable(result.dispute).first
      expect(log.action).to eq("reported")
    end

    it "requires card_last4 for this kind" do
      result = described_class.new(actor: actor, daily_reconciliation_id: dr.id, params: atm_params.except(:card_last4)).call

      expect(result.ok?).to be false
    end

    it "attaches photos when given" do
      file = Rack::Test::UploadedFile.new(StringIO.new("fake image data"), "image/png", original_filename: "receipt.png")

      result = described_class.new(actor: actor, daily_reconciliation_id: dr.id,
                                    params: atm_params.merge(photos: [ file ])).call

      expect(result.ok?).to be true
      expect(result.dispute.photos.count).to eq(1)
    end

    it "only finds reconciliations within the actor's business" do
      other_business = create(:business)
      other_actor = create(:user, business: other_business)

      expect {
        described_class.new(actor: other_actor, daily_reconciliation_id: dr.id, params: atm_params).call
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
