require "rails_helper"

RSpec.describe Finance::BankStatements::Unmatcher do
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

  let(:deposit) do
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation, payment_method: payment_method,
      deposited_by: actor, amount: 300, deposited_at: Time.current
    )
  end

  let(:txn) do
    BankStatementTransaction.create!(
      bank_statement: statement, business: business, transaction_date: Date.current,
      amount: 300, raw_data: {}, status: "verified",
      matched_till_deposit_id: deposit.id, match_method: "manual", matched_at: Time.current
    )
  end

  describe ".call" do
    it "clears the match and returns the transaction to unexpected" do
      result = described_class.call(txn.id, actor: actor, notes: "wrong deposit")

      expect(result).to be_ok
      txn.reload
      expect(txn.matched_till_deposit_id).to be_nil
      expect(txn.match_method).to be_nil
      expect(txn.matched_by).to be_nil
      expect(txn.matched_at).to be_nil
      expect(txn.status).to eq("unexpected")
    end

    it "frees the deposit so it can be matched to a different transaction" do
      described_class.call(txn.id, actor: actor)

      expect(TillDeposit.find(deposit.id).bank_statement_transaction).to be_nil
    end

    it "writes an audit log entry referencing the previous deposit" do
      expect {
        described_class.call(txn.id, actor: actor, notes: "wrong deposit")
      }.to change { AuditLog.for_auditable(txn).count }.by(1)

      log = AuditLog.for_auditable(txn).last
      expect(log.action).to eq("manual_unmatch")
      expect(log.metadata["previous_till_deposit_id"]).to eq(deposit.id)
      expect(log.metadata["notes"]).to eq("wrong deposit")
    end

    it "decrements matched_rows and increments unmatched_rows on the statement" do
      statement.update_columns(matched_rows: 1, unmatched_rows: 0)

      described_class.call(txn.id, actor: actor)

      statement.reload
      expect(statement.matched_rows).to eq(0)
      expect(statement.unmatched_rows).to eq(1)
    end

    it "refuses to unmatch a transaction that isn't currently matched" do
      txn.update!(matched_till_deposit_id: nil, match_method: nil, matched_at: nil, status: "unexpected")

      result = described_class.call(txn.id, actor: actor)

      expect(result).not_to be_ok
    end
  end
end
