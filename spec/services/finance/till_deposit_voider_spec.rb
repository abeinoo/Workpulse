require "rails_helper"

RSpec.describe Finance::TillDepositVoider, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:cash_pm) do
    PaymentMethod.create!(
      business:        business,
      name:            "Cash",
      settlement_type: "cash",
      active:          true
    )
  end

  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: Date.current
    )
  end

  let!(:till_session)   { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(
      daily_reconciliation: dr,
      payment_method:       cash_pm,
      payment_method_name:  cash_pm.name,
      collected_amount:     17_900,
      refund_amount:        0
    )
  end

  def deposit(amount:)
    Finance::TillDepositRecorder.new(
      dr.id, actor: actor,
      params: { payment_method_id: cash_pm.id, amount: amount.to_s, deposited_at: Time.current.to_s }
    ).call.deposit
  end

  def void(deposit, reason: "Wrong amount entered")
    described_class.new(deposit.id, actor: actor, void_reason: reason).call
  end

  describe "#call" do
    it "excludes the voided deposit from total_deposited and pending_deposit_amount" do
      d = deposit(amount: 15_750)
      expect(dr.reload.total_deposited).to eq(15_750)

      result = void(d)
      expect(result.ok?).to be true
      expect(dr.reload.total_deposited).to eq(0)
      expect(dr.pending_deposit_amount).to eq(17_900)
    end

    it "does not touch any existing RemainingDepositBalance — voiding does not try to restore responsibility" do
      d = deposit(amount: 15_750)
      rdb = RemainingDepositBalance.sole
      expect(rdb.remaining_amount).to eq(2_150)

      void(d)

      expect(rdb.reload.remaining_amount).to eq(2_150)
      expect(rdb.status).to eq("open")
      expect(RemainingDepositBalance.count).to eq(1)
    end

    it "does not create a RemainingDepositBalance on void, even when the voided deposit had fully covered the PM" do
      d = deposit(amount: 17_900)
      expect(RemainingDepositBalance.count).to eq(0)

      void(d)

      expect(RemainingDepositBalance.count).to eq(0)
    end

    it "allows immediately re-depositing the full correct amount after voiding the wrong one" do
      wrong = deposit(amount: 15_750)
      void(wrong)

      result = Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: cash_pm.id, amount: "17900.00", deposited_at: Time.current.to_s }
      ).call

      expect(result.ok?).to be true
      expect(result.remaining_amount).to be_nil
      expect(dr.reload.total_deposited).to eq(17_900)
      expect(dr.pending_deposit_amount).to eq(0)
      expect(RemainingDepositBalance.sole.reload.status).to eq("settled")
    end

    it "reverts the DR from deposited back to closed when the voided deposit was the only one" do
      d = deposit(amount: 17_900)
      expect(dr.reload.state).to eq("deposited")

      void(d)
      expect(dr.reload.state).to eq("closed")
    end

    it "keeps the DR deposited when another active deposit still exists" do
      other_pm = PaymentMethod.create!(business: business, name: "Cash USD", settlement_type: "cash", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: other_pm,
                                 payment_method_name: other_pm.name, collected_amount: 100, refund_amount: 0)
      Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: other_pm.id, amount: "100.00", deposited_at: Time.current.to_s }
      ).call

      d = deposit(amount: 17_900)
      void(d)

      expect(dr.reload.state).to eq("deposited")
    end

    it "writes an audit log entry for the void" do
      d = deposit(amount: 15_750)
      void(d)
      expect(AuditLog.where(auditable: d, action: "void").count).to eq(1)
    end

    it "rejects voiding an already-voided deposit" do
      d = deposit(amount: 15_750)
      void(d)
      result = void(d)

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("till_deposits.errors.already_voided"))
    end

    it "preserves the original deposit, the void, and the replacement as three distinct audit events" do
      original = deposit(amount: 15_750)
      void(original)
      replacement = Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: cash_pm.id, amount: "17900.00", deposited_at: Time.current.to_s }
      ).call.deposit

      expect(AuditLog.where(auditable: original, action: "create").count).to eq(1)
      expect(AuditLog.where(auditable: original, action: "void").count).to eq(1)
      expect(AuditLog.where(auditable: replacement, action: "create").count).to eq(1)
      expect(TillDeposit.count).to eq(2)
      expect(original.id).not_to eq(replacement.id)
    end
  end

  describe "bank statement matches held by the voided deposit" do
    let(:statement) do
      create(:bank_statement, :pending, business: business, branch: branch,
             statement_from: Date.current - 2.days, statement_to: Date.current + 2.days)
    end

    # Dated on the deposit's own calendar day in the business timezone — the
    # date the matching engine compares against.
    def bank_txn(amount:)
      BankStatementTransaction.create!(
        bank_statement: statement, business: business, amount: amount, raw_data: {}, status: "pending",
        transaction_date: Time.current.in_time_zone(business.timezone_object).to_date
      )
    end

    def auto_match!
      Finance::DepositVerification::MatchingEngine.call(statement.id, actor: actor)
    end

    def release_audits
      AuditLog.where(auditable_type: "BankStatementTransaction", action: "released_by_deposit_void")
    end

    it "releases nothing when the voided deposit was never matched" do
      d = deposit(amount: 15_750)
      t = bank_txn(amount: 999)
      auto_match!
      status_before = t.reload.status

      expect(void(d)).to be_ok
      expect(release_audits).to be_empty
      expect(t.reload.status).to eq(status_before)
      expect(statement.reload.matched_rows).to eq(0)
    end

    it "releases the match, keeps the transaction, and audits the release" do
      d = deposit(amount: 17_900)
      t = bank_txn(amount: 17_900)
      auto_match!
      expect(t.reload.status).to eq("verified")
      expect(statement.reload.matched_rows).to eq(1)

      expect(void(d)).to be_ok

      expect(d.reload).to be_voided
      t.reload
      expect(t.status).to eq("unexpected")
      expect(t.matched_till_deposit).to be_nil
      expect(DepositMatch.where(till_deposit_id: d.id)).to be_empty
      expect(statement.reload.matched_rows).to eq(0)
      expect(statement.unmatched_rows).to eq(1)

      audit = release_audits.sole
      expect(audit.auditable).to eq(t)
      expect(audit.actor).to eq(actor)
      expect(audit.metadata).to include("till_deposit_id" => d.id, "previous_till_deposit_id" => d.id,
                                        "void_reason" => "Wrong amount entered")
      # Released before the void, so the stale-link "re-verification" path never fires.
      expect(AuditLog.where(auditable: t, action: "verification_invalidated")).to be_empty
    end

    it "never auto-matches the replacement, but lets it be matched manually" do
      original = deposit(amount: 17_900)
      t = bank_txn(amount: 17_900)
      auto_match!
      void(original)

      replacement = deposit(amount: 17_900)
      expect(t.reload.matched_till_deposit).to be_nil
      expect(t.status).to eq("unexpected")

      result = Finance::BankStatements::ManualMatcher.call(t.id, till_deposit_id: replacement.id,
                                                           actor: actor, notes: "Re-deposit after void")
      expect(result).to be_ok
      t.reload
      expect(t.matched_till_deposit).to eq(replacement)
      expect(t.status).to eq("verified")
      expect(t.match_method).to eq("manual")
      expect(statement.reload.matched_rows).to eq(1)
      expect(statement.unmatched_rows).to eq(0)
    end

    it "keeps DR totals and match figures consistent after the void and the replacement match" do
      original = deposit(amount: 17_900)
      t = bank_txn(amount: 17_900)
      auto_match!
      expect(dr.reload.total_matched_amount).to eq(17_900)

      void(original)
      expect(dr.reload.total_deposited).to eq(0)
      expect(dr.total_matched_amount).to eq(0)

      replacement = deposit(amount: 17_900)
      Finance::BankStatements::ManualMatcher.call(t.id, till_deposit_id: replacement.id, actor: actor, notes: "ok")
      expect(dr.reload.total_deposited).to eq(17_900)
      expect(dr.total_matched_amount).to eq(17_900)
      expect(DepositMatch.where(bank_statement_transaction_id: t.id).count).to eq(1)
    end

    it "refuses to match the released transaction to a second deposit, or to the voided one" do
      original = deposit(amount: 17_900)
      t = bank_txn(amount: 17_900)
      auto_match!
      void(original)
      replacement = deposit(amount: 17_900)
      Finance::BankStatements::ManualMatcher.call(t.id, till_deposit_id: replacement.id, actor: actor, notes: "ok")

      other = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                                  amount: 17_900, deposited_at: Time.current)
      second = Finance::BankStatements::ManualMatcher.call(t.id, till_deposit_id: other.id, actor: actor, notes: "dup")
      expect(second).not_to be_ok
      expect(second.error).to eq(I18n.t("finance.bank_statements.errors.already_matched_to_another_deposit"))

      to_voided = Finance::BankStatements::ManualMatcher.call(t.id, till_deposit_id: original.id, actor: actor, notes: "x")
      expect(to_voided).not_to be_ok
      expect(DepositMatch.where(bank_statement_transaction_id: t.id).pluck(:till_deposit_id)).to eq([ replacement.id ])
    end

    it "rolls back the release when the void itself fails" do
      d = deposit(amount: 17_900)
      t = bank_txn(amount: 17_900)
      auto_match!

      result = void(d, reason: "")

      expect(result).not_to be_ok
      expect(d.reload).not_to be_voided
      t.reload
      expect(t.status).to eq("verified")
      expect(t.matched_till_deposit).to eq(d)
      expect(statement.reload.matched_rows).to eq(1)
      expect(statement.unmatched_rows).to eq(0)
      expect(release_audits).to be_empty
      expect(AuditLog.where(auditable: d, action: "void")).to be_empty
    end
  end
end
