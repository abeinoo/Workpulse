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

  def deposit(amount: 300)
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation,
      payment_method:       payment_method,
      deposited_by:         actor,
      amount:                amount,
      deposited_at:          Time.current,
      reference:             "DEP-1"
    )
  end

  def txn(amount: 300, status: "unexpected")
    BankStatementTransaction.create!(
      bank_statement:   statement,
      business:         business,
      transaction_date: Date.current,
      amount:            amount,
      raw_data:          {},
      status:            status
    )
  end

  describe ".call — single transaction to one deposit" do
    it "links the transaction to the deposit and marks it verified" do
      dep = deposit
      transaction = txn

      result = described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed with branch")

      expect(result).to be_ok
      transaction.reload
      expect(transaction.matched_till_deposit).to eq(dep)
      expect(transaction.status).to eq("verified")
      expect(dep.reload.match_status).to eq(:fully_matched)
    end

    it "records matched_by, matched_at, match_method, and the notes as the matching reason" do
      dep = deposit
      transaction = txn

      travel_to Time.zone.local(2026, 7, 15, 10, 0, 0) do
        described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed with branch")
      end

      transaction.reload
      expect(transaction.matched_by).to eq(actor)
      expect(transaction.matched_at).to be_present
      expect(transaction.match_method).to eq("manual")
      expect(transaction.match_notes).to eq("confirmed with branch")
    end

    it "writes an audit log entry for the manual match" do
      dep = deposit
      transaction = txn

      expect {
        described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed")
      }.to change { AuditLog.for_auditable(transaction).count }.by(1)

      log = AuditLog.for_auditable(transaction).last
      expect(log.action).to eq("manual_match")
      expect(log.actor).to eq(actor)
      expect(log.metadata["till_deposit_id"]).to eq(dep.id)
    end

    it "increments the statement's matched_rows and decrements unmatched_rows" do
      dep = deposit
      transaction = txn
      statement.update_columns(matched_rows: 0, unmatched_rows: 1)

      described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed")

      statement.reload
      expect(statement.matched_rows).to eq(1)
      expect(statement.unmatched_rows).to eq(0)
    end

    it "refuses to match a transaction already claimed by a different deposit" do
      dep       = deposit
      other_dep = deposit
      transaction = txn(status: "verified")
      DepositMatch.create_for!(till_deposit: other_dep, bank_statement_transaction: transaction, matched_by: actor)

      result = described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed")

      expect(result).not_to be_ok
      expect(transaction.reload.matched_till_deposit).to eq(other_dep)
    end

    it "is a no-op (still ok) when re-submitted for the same deposit it's already matched to" do
      dep = deposit
      transaction = txn(status: "verified")
      DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: transaction, matched_by: actor)

      result = described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed")

      expect(result).to be_ok
      expect(DepositMatch.where(bank_statement_transaction_id: transaction.id).count).to eq(1)
    end
  end

  describe "mandatory reason" do
    it "rejects a single match with no reason" do
      dep = deposit
      transaction = txn

      result = described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: nil)

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("finance.bank_statements.errors.reason_required"))
      expect(transaction.reload.matched?).to be false
    end

    it "rejects a single match with a blank/whitespace-only reason" do
      dep = deposit
      transaction = txn

      result = described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "   ")

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("finance.bank_statements.errors.reason_required"))
    end

    it "rejects a call_many batch with no reason, linking nothing" do
      dep   = deposit(amount: 300)
      txn_a = txn(amount: 300)

      result = described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn_a.id ], actor: actor)

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("finance.bank_statements.errors.reason_required"))
      expect(txn_a.reload.matched?).to be false
    end
  end

  describe ".call_many — one deposit, multiple transactions" do
    it "links several transactions to one deposit whose amounts sum exactly to it (Fully Matched)" do
      dep = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)
      txn_b = txn(amount: 4_700)

      result = described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn_a.id, txn_b.id ], actor: actor, notes: "confirmed")

      expect(result).to be_ok
      expect(txn_a.reload.status).to eq("verified")
      expect(txn_b.reload.status).to eq("verified")
      expect(dep.reload.match_status).to eq(:fully_matched)
      expect(dep.matched_total).to eq(11_700)
    end

    it "allows a total less than the deposit amount to persist as Partially Matched" do
      dep = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)

      result = described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn_a.id ], actor: actor, notes: "confirmed")

      expect(result).to be_ok
      expect(dep.reload.match_status).to eq(:partially_matched)
      expect(dep.matched_total).to eq(7_000)
    end

    it "rejects a total greater than the deposit amount (Over Matched prevented) and links nothing" do
      dep = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)
      txn_b = txn(amount: 6_000)

      result = described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn_a.id, txn_b.id ], actor: actor, notes: "confirmed")

      expect(result).not_to be_ok
      expect(result.error).to eq(I18n.t("finance.bank_statements.errors.exceeds_deposit_amount"))
      expect(txn_a.reload.matched?).to be false
      expect(txn_b.reload.matched?).to be false
      expect(dep.reload.match_status).to eq(:unmatched)
    end

    it "rejects adding a transaction that would push an already-partially-matched deposit over its amount" do
      dep = deposit(amount: 11_700)
      described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn(amount: 7_000).id ], actor: actor, notes: "confirmed")

      result = described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn(amount: 6_000).id ], actor: actor, notes: "confirmed")

      expect(result).not_to be_ok
      expect(dep.reload.match_status).to eq(:partially_matched)
      expect(dep.matched_total).to eq(7_000)
    end

    it "completes a partially-matched deposit incrementally across two separate calls" do
      dep = deposit(amount: 11_700)
      described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn(amount: 7_000).id ], actor: actor, notes: "confirmed")
      expect(dep.reload.match_status).to eq(:partially_matched)

      described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn(amount: 4_700).id ], actor: actor, notes: "confirmed")

      expect(dep.reload.match_status).to eq(:fully_matched)
      expect(dep.matched_total).to eq(11_700)
    end

    it "writes one audit log entry per linked transaction" do
      dep = deposit(amount: 11_700)
      txn_a = txn(amount: 7_000)
      txn_b = txn(amount: 4_700)

      described_class.call_many(till_deposit_id: dep.id, transaction_ids: [ txn_a.id, txn_b.id ], actor: actor, notes: "confirmed")

      expect(AuditLog.where(auditable: txn_a, action: "manual_match").count).to eq(1)
      expect(AuditLog.where(auditable: txn_b, action: "manual_match").count).to eq(1)
    end
  end

  describe "removing a matched transaction, then re-matching" do
    it "allows re-matching a transaction to a different deposit after it has been unmatched" do
      dep       = deposit
      other_dep = deposit
      transaction = txn

      described_class.call(transaction.id, till_deposit_id: dep.id, actor: actor, notes: "confirmed")
      Finance::BankStatements::Unmatcher.call(transaction.id, actor: actor)

      result = described_class.call(transaction.id, till_deposit_id: other_dep.id, actor: actor, notes: "confirmed")

      expect(result).to be_ok
      expect(transaction.reload.matched_till_deposit).to eq(other_dep)
    end
  end
end
