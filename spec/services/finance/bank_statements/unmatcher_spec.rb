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

  def link!(dep, transaction, matched_by: actor)
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: transaction, matched_by: matched_by)
    transaction.update!(match_method: "manual", match_confidence: 100, status: "verified")
  end

  describe ".call" do
    it "refuses a second release of the same match without touching the statement counters again" do
      transaction = txn
      link!(deposit, transaction)
      statement.update_columns(matched_rows: 1, unmatched_rows: 0)

      expect(described_class.call(transaction.id, actor: actor, notes: "first")).to be_ok
      second = described_class.call(transaction.id, actor: actor, notes: "second")

      expect(second).not_to be_ok
      expect(statement.reload.matched_rows).to eq(0)
      expect(statement.unmatched_rows).to eq(1)
      expect(AuditLog.where(auditable: transaction, action: "manual_unmatch").count).to eq(1)
    end

    it "clears the match and returns the transaction to unexpected" do
      dep = deposit
      transaction = txn
      link!(dep, transaction)

      result = described_class.call(transaction.id, actor: actor, notes: "wrong deposit")

      expect(result).to be_ok
      transaction.reload
      expect(transaction.matched_till_deposit).to be_nil
      expect(transaction.match_method).to be_nil
      expect(transaction.matched_by).to be_nil
      expect(transaction.matched_at).to be_nil
      expect(transaction.status).to eq("unexpected")
      expect(DepositMatch.where(bank_statement_transaction_id: transaction.id)).to be_empty
    end

    it "frees the deposit so it can be matched to a different transaction" do
      dep = deposit
      transaction = txn
      link!(dep, transaction)

      described_class.call(transaction.id, actor: actor)

      expect(TillDeposit.find(dep.id).bank_statement_transactions).to be_empty
      expect(TillDeposit.find(dep.id).match_status).to eq(:unmatched)
    end

    it "keeps a deposit's other matched transactions intact when only one is removed" do
      dep    = deposit(amount: 11_700)
      txn_a  = txn(amount: 7_000)
      txn_b  = txn(amount: 4_700)
      link!(dep, txn_a)
      link!(dep, txn_b)
      expect(dep.match_status).to eq(:fully_matched)

      described_class.call(txn_a.id, actor: actor)

      expect(dep.reload.match_status).to eq(:partially_matched)
      expect(dep.bank_statement_transactions.reload).to contain_exactly(txn_b)
    end

    it "writes an audit log entry referencing the previous deposit" do
      dep = deposit
      transaction = txn
      link!(dep, transaction)

      expect {
        described_class.call(transaction.id, actor: actor, notes: "wrong deposit")
      }.to change { AuditLog.for_auditable(transaction).count }.by(1)

      log = AuditLog.for_auditable(transaction).last
      expect(log.action).to eq("manual_unmatch")
      expect(log.metadata["previous_till_deposit_id"]).to eq(dep.id)
      expect(log.metadata["notes"]).to eq("wrong deposit")
    end

    it "decrements matched_rows and increments unmatched_rows on the statement" do
      dep = deposit
      transaction = txn
      link!(dep, transaction)
      statement.update_columns(matched_rows: 1, unmatched_rows: 0)

      described_class.call(transaction.id, actor: actor)

      statement.reload
      expect(statement.matched_rows).to eq(0)
      expect(statement.unmatched_rows).to eq(1)
    end

    it "refuses to unmatch a transaction that isn't currently matched" do
      transaction = txn

      result = described_class.call(transaction.id, actor: actor)

      expect(result).not_to be_ok
    end
  end
end
