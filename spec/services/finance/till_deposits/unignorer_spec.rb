require "rails_helper"

RSpec.describe Finance::TillDeposits::Unignorer do
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

  def deposit(amount: 300)
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation, payment_method: payment_method,
      deposited_by: actor, amount: amount, deposited_at: Time.current
    )
  end

  describe ".call" do
    it "clears the ignore state, restoring the deposit to Missing from Bank" do
      dep = deposit
      Finance::TillDeposits::Ignorer.call(dep.id, actor: actor, reason: "test")

      result = described_class.call(dep.id, actor: actor)

      expect(result).to be_ok
      dep.reload
      expect(dep).not_to be_ignored
      expect(dep.ignored_by).to be_nil
      expect(dep.ignore_reason).to be_nil
      expect(dep.ignored_at).to be_nil
    end

    it "writes an audit log entry" do
      dep = deposit
      Finance::TillDeposits::Ignorer.call(dep.id, actor: actor, reason: "test reason")

      expect {
        described_class.call(dep.id, actor: actor)
      }.to change { AuditLog.for_auditable(dep).where(action: "unignored").count }.by(1)

      log = AuditLog.for_auditable(dep).where(action: "unignored").last
      expect(log.actor).to eq(actor)
      expect(log.metadata["previous_reason"]).to eq("test reason")
    end

    it "refuses to unignore a deposit that isn't ignored" do
      dep = deposit

      result = described_class.call(dep.id, actor: actor)

      expect(result).not_to be_ok
    end
  end
end
