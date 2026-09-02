require "rails_helper"

RSpec.describe Finance::TillDeposits::Ignorer do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:payment_method) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end

  let(:daily_reconciliation) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, business_date: Date.current
    )
  end

  let(:statement) { create(:bank_statement, :pending, business: business, branch: branch) }

  def deposit(amount: 300)
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation, payment_method: payment_method,
      deposited_by: actor, amount: amount, deposited_at: Time.current
    )
  end

  def txn(amount: 300)
    BankStatementTransaction.create!(
      bank_statement: statement, business: business, transaction_date: Date.current,
      amount: amount, raw_data: {}, status: "unexpected"
    )
  end

  describe ".call" do
    it "marks the deposit as ignored with an optional reason" do
      dep = deposit

      result = described_class.call(dep.id, actor: actor, reason: "Settled outside the bank")

      expect(result).to be_ok
      dep.reload
      expect(dep).to be_ignored
      expect(dep.ignored_by).to eq(actor)
      expect(dep.ignore_reason).to eq("Settled outside the bank")
      expect(dep.ignored_at).to be_present
    end

    it "allows a blank reason since it is optional" do
      dep = deposit

      result = described_class.call(dep.id, actor: actor, reason: nil)

      expect(result).to be_ok
      expect(dep.reload.ignore_reason).to be_nil
    end

    it "does not touch financial fields on the deposit" do
      dep = deposit(amount: 500)

      described_class.call(dep.id, actor: actor)

      dep.reload
      expect(dep.amount).to eq(500)
      expect(dep.voided_at).to be_nil
    end

    it "writes an audit log entry" do
      dep = deposit

      expect {
        described_class.call(dep.id, actor: actor, reason: "duplicate cash count")
      }.to change { AuditLog.for_auditable(dep).count }.by(1)

      log = AuditLog.for_auditable(dep).last
      expect(log.action).to eq("ignored")
      expect(log.actor).to eq(actor)
      expect(log.metadata["reason"]).to eq("duplicate cash count")
      expect(log.metadata["previous_status"]).to eq("missing")
      expect(log.metadata["new_status"]).to eq("ignored")
    end

    it "refuses to ignore an already-ignored deposit" do
      dep = deposit
      described_class.call(dep.id, actor: actor)

      result = described_class.call(dep.id, actor: actor)

      expect(result).not_to be_ok
      expect(result.error).to be_present
    end

    it "refuses to ignore a deposit that already has a matched bank transaction" do
      dep = deposit(amount: 300)
      transaction = txn(amount: 300)
      DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: transaction, matched_by: actor)

      result = described_class.call(dep.id, actor: actor)

      expect(result).not_to be_ok
      expect(dep.reload).not_to be_ignored
    end

    it "refuses to ignore a voided deposit" do
      dep = deposit
      dep.update!(voided_at: Time.current, voided_by: actor, void_reason: "mistake")

      result = described_class.call(dep.id, actor: actor)

      expect(result).not_to be_ok
      expect(dep.reload).not_to be_ignored
    end

    it "scopes lookup to the actor's own business" do
      other_business = create(:business)
      other_actor    = create(:user, business: other_business)
      dep            = deposit

      result = described_class.call(dep.id, actor: other_actor)

      expect(result).not_to be_ok
    end
  end
end
