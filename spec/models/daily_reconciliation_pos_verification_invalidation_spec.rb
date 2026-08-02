require "rails_helper"

RSpec.describe DailyReconciliation, "#invalidate_bank_verification_for_pos_change! / #clear_verification!" do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "deposited",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.new(2026, 7, 16),
      reviewed_by: actor, reviewed_at: 1.minute.ago
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  def collect_cash!(amount)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                              payment_method_name: cash_pm.name, collected_amount: amount, refund_amount: 0)
  end

  def deposit(amount:, deposited_at: Time.zone.local(2026, 7, 16, 14, 0, 0))
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: amount, deposited_at: deposited_at)
  end

  def statement(from: Date.new(2026, 7, 16), to: Date.new(2026, 7, 16))
    create(:bank_statement, business: business, branch: branch, statement_from: from, statement_to: to)
  end

  def txn(stmt, amount:, transaction_date: Date.new(2026, 7, 16))
    BankStatementTransaction.create!(bank_statement: stmt, business: business, transaction_date: transaction_date,
                                     amount: amount, raw_data: {}, status: "unexpected")
  end

  def link!(dep, transaction)
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: transaction, matched_by: actor)
    transaction.update!(status: "verified", match_method: "manual")
  end

  def fully_matched_dr!
    collect_cash!(500)
    dep = deposit(amount: 500)
    stmt = statement
    matched_txn = txn(stmt, amount: 500)
    link!(dep, matched_txn)
    matched_txn
  end

  describe "#invalidate_bank_verification_for_pos_change!" do
    it "no-ops when bank matching is not yet completed" do
      collect_cash!(500)
      deposit(amount: 500)
      statement
      expect(dr.bank_reconciliation_status).to eq("waiting_for_matching")

      expect { dr.invalidate_bank_verification_for_pos_change!(actor: actor) }
        .not_to change { AuditLog.count }
    end

    it "flips every matched, non-ignored BankStatementTransaction to needs_reverification once matching was completed" do
      matched_txn = fully_matched_dr!
      expect(dr.bank_reconciliation_status).to eq("completed")

      dr.invalidate_bank_verification_for_pos_change!(actor: actor)

      expect(matched_txn.reload.status).to eq("needs_reverification")
      expect(dr.bank_reconciliation_status).to eq("needs_review")
    end

    it "never touches an ignored transaction" do
      matched_txn = fully_matched_dr!
      # The match itself (DepositMatch#matched_amount) still counts toward
      # the deposit's own match_status regardless of the linked transaction's
      # status, so marking it "ignored" afterward still leaves the DR reading
      # "completed" overall — the scenario where an ignored transaction could
      # otherwise get swept up by the invalidation below.
      matched_txn.update!(status: "ignored")
      expect(dr.bank_reconciliation_status).to eq("completed")

      dr.invalidate_bank_verification_for_pos_change!(actor: actor)

      expect(matched_txn.reload.status).to eq("ignored")
    end

    it "logs a verification_invalidated audit event per affected transaction" do
      matched_txn = fully_matched_dr!

      expect { dr.invalidate_bank_verification_for_pos_change!(actor: actor) }
        .to change { AuditLog.where(auditable: matched_txn, action: "verification_invalidated").count }.by(1)
    end

    it "also clears an already-verified DR's verification state" do
      matched_txn = fully_matched_dr!
      dr.update!(state: "verified", verified_by: actor, verified_at: 1.minute.ago)

      dr.invalidate_bank_verification_for_pos_change!(actor: actor)

      expect(matched_txn.reload.status).to eq("needs_reverification")
      expect(dr.reload.verified?).to be false
      expect(dr.state).to eq("deposited")
    end

    it "does not touch verification state when the DR was never verified" do
      fully_matched_dr!

      expect { dr.invalidate_bank_verification_for_pos_change!(actor: actor) }
        .not_to change { dr.reload.state }
    end
  end

  describe "#clear_verification!" do
    it "no-ops (and logs nothing) when not currently verified" do
      expect { dr.clear_verification!(actor: actor) }.not_to change { AuditLog.count }
    end

    it "resets verified_at/verified_by and reverts state to deposited when an active deposit exists" do
      deposit(amount: 500)
      dr.update!(state: "verified", verified_by: actor, verified_at: 1.minute.ago)

      dr.clear_verification!(actor: actor)

      expect(dr.verified?).to be false
      expect(dr.verified_by_id).to be_nil
      expect(dr.state).to eq("deposited")
    end

    it "reverts state to closed when there is no active deposit" do
      dr.update!(state: "verified", verified_by: actor, verified_at: 1.minute.ago)

      dr.clear_verification!(actor: actor)

      expect(dr.state).to eq("closed")
    end
  end
end
