require "rails_helper"

RSpec.describe Finance::BankStatements::ManualMatcher do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:payment_method) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end

  let(:daily_reconciliation) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      business_date: Date.current
    )
  end

  let(:statement) { create(:bank_statement, :pending, business: business, branch: branch) }

  let(:deposit) do
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation,
      payment_method:       payment_method,
      deposited_by:         actor,
      amount:                300,
      deposited_at:          Time.current,
      reference:             "DEP-1"
    )
  end

  let(:txn) do
    BankStatementTransaction.create!(
      bank_statement:   statement,
      business:         business,
      transaction_date: Date.current,
      amount:            300,
      raw_data:          {},
      status:            "unexpected"
    )
  end

  describe ".call" do
    it "links the transaction to the deposit and marks it verified" do
      result = described_class.call(txn.id, till_deposit_id: deposit.id, actor: actor, notes: "confirmed with branch")

      expect(result).to be_ok
      txn.reload
      expect(txn.matched_till_deposit_id).to eq(deposit.id)
      expect(txn.status).to eq("verified")
    end

    it "records matched_by, matched_at, match_method, and the notes as the matching reason" do
      travel_to Time.zone.local(2026, 7, 15, 10, 0, 0) do
        described_class.call(txn.id, till_deposit_id: deposit.id, actor: actor, notes: "confirmed with branch")
      end

      txn.reload
      expect(txn.matched_by).to eq(actor)
      expect(txn.matched_at).to be_present
      expect(txn.match_method).to eq("manual")
      expect(txn.match_notes).to eq("confirmed with branch")
    end

    it "writes an audit log entry for the manual match" do
      expect {
        described_class.call(txn.id, till_deposit_id: deposit.id, actor: actor, notes: "confirmed")
      }.to change { AuditLog.for_auditable(txn).count }.by(1)

      log = AuditLog.for_auditable(txn).last
      expect(log.action).to eq("manual_match")
      expect(log.actor).to eq(actor)
      expect(log.metadata["till_deposit_id"]).to eq(deposit.id)
    end

    it "increments the statement's matched_rows and decrements unmatched_rows" do
      statement.update_columns(matched_rows: 0, unmatched_rows: 1)

      described_class.call(txn.id, till_deposit_id: deposit.id, actor: actor)

      statement.reload
      expect(statement.matched_rows).to eq(1)
      expect(statement.unmatched_rows).to eq(0)
    end

    it "refuses to match a deposit that is already claimed by a different transaction" do
      other_txn = BankStatementTransaction.create!(
        bank_statement: statement, business: business, transaction_date: Date.current,
        amount: 300, raw_data: {}, status: "verified",
        matched_till_deposit_id: deposit.id, match_method: "manual", matched_at: Time.current
      )

      result = described_class.call(txn.id, till_deposit_id: deposit.id, actor: actor)

      expect(result).not_to be_ok
      txn.reload
      expect(txn.matched_till_deposit_id).to be_nil
      expect(other_txn.reload.matched_till_deposit_id).to eq(deposit.id)
    end

    it "allows re-matching a transaction to a different deposit than it already had (net-zero on counters)" do
      other_deposit = TillDeposit.create!(
        daily_reconciliation: daily_reconciliation, payment_method: payment_method,
        deposited_by: actor, amount: 300, deposited_at: Time.current
      )
      txn.update!(matched_till_deposit_id: deposit.id, match_method: "manual",
                  matched_at: Time.current, status: "verified")
      statement.update_columns(matched_rows: 1, unmatched_rows: 0)

      result = described_class.call(txn.id, till_deposit_id: other_deposit.id, actor: actor)

      expect(result).to be_ok
      txn.reload
      expect(txn.matched_till_deposit_id).to eq(other_deposit.id)
      expect(statement.reload.matched_rows).to eq(1)
    end
  end
end
