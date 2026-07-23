require "rails_helper"

RSpec.describe Finance::DepositVerification::MatchingEngine do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:payment_method) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end

  let(:business_date) { Date.new(2026, 7, 12) }

  let(:daily_reconciliation) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     business_date.to_time - 1.hour,
      business_date: business_date
    )
  end

  let(:statement) do
    create(:bank_statement, :pending,
           business:       business,
           branch:         branch,
           statement_from: business_date - 1.day,
           statement_to:   business_date + 1.day)
  end

  def deposit(amount:, date: business_date, reference: nil, notes: nil)
    TillDeposit.create!(
      daily_reconciliation: daily_reconciliation,
      payment_method:       payment_method,
      deposited_by:         actor,
      amount:                amount,
      deposited_at:          date.to_time + 12.hours,
      reference:             reference,
      notes:                 notes
    )
  end

  def transaction(amount:, date: business_date, reference: nil, description: nil)
    BankStatementTransaction.create!(
      bank_statement:   statement,
      business:         business,
      transaction_date: date,
      amount:            amount,
      reference_number:  reference,
      description:       description,
      raw_data:          {},
      status:            "pending"
    )
  end

  def run!
    described_class.call(statement.id, actor: actor)
  end

  # ── Issue 1 — duplicate transactions matched one-to-one ─────────────────── #

  describe "duplicate amounts, equal counts" do
    it "matches 300/300/300 vs 300/300/300 as 3 clean matches, never reusing a deposit" do
      d1 = deposit(amount: 300)
      d2 = deposit(amount: 300)
      d3 = deposit(amount: 300)
      t1 = transaction(amount: 300)
      t2 = transaction(amount: 300)
      t3 = transaction(amount: 300)

      result = run!

      expect(result).to be_ok
      expect(result.matched).to eq(3)
      expect(result.unmatched).to eq(0)
      expect(result.needs_review).to eq(0)

      [ t1, t2, t3 ].each(&:reload)
      matched_deposit_ids = [ t1, t2, t3 ].map(&:matched_till_deposit_id)

      expect(matched_deposit_ids).to match_array([ d1.id, d2.id, d3.id ])
      expect(matched_deposit_ids.uniq.size).to eq(3) # no deposit used twice
      [ t1, t2, t3 ].each { |t| expect(t.status).to eq("verified") }
    end

    it "matches the original bug report shape: 300/300/200/7400 vs 300/300/200/7400" do
      d300a = deposit(amount: 300)
      d300b = deposit(amount: 300)
      d200  = deposit(amount: 200)
      d7400 = deposit(amount: 7400)
      t300a = transaction(amount: 300)
      t300b = transaction(amount: 300)
      t200  = transaction(amount: 200)
      t7400 = transaction(amount: 7400)

      result = run!

      expect(result.matched).to eq(4)
      expect(result.unmatched).to eq(0)

      [ t300a, t300b, t200, t7400 ].each(&:reload)
      expect(t300a.matched_till_deposit_id).not_to eq(t300b.matched_till_deposit_id)
      expect([ t300a, t300b ].map(&:matched_till_deposit_id)).to match_array([ d300a.id, d300b.id ])
      expect(t200.matched_till_deposit_id).to eq(d200.id)
      expect(t7400.matched_till_deposit_id).to eq(d7400.id)
    end
  end

  describe "duplicate amounts, deposit deficit (fewer deposits than transactions)" do
    it "matches 300,300 (transactions) vs 300 (deposit) as 1 matched, 1 unmatched" do
      d1 = deposit(amount: 300)
      t1 = transaction(amount: 300)
      t2 = transaction(amount: 300)

      result = run!

      expect(result.matched).to eq(1)
      expect(result.unmatched).to eq(1)
      expect(result.needs_review).to eq(0)

      t1.reload
      t2.reload
      matched, unmatched = [ t1, t2 ].partition(&:matched?)
      expect(matched.size).to eq(1)
      expect(matched.first.matched_till_deposit_id).to eq(d1.id)
      expect(unmatched.size).to eq(1)
      expect(unmatched.first.status).to eq("unexpected")
    end
  end

  describe "duplicate amounts, deposit surplus (more deposits than transactions)" do
    it "flags the transaction as needs_manual_review instead of guessing which deposit is correct" do
      deposit(amount: 300)
      deposit(amount: 300)
      t1 = transaction(amount: 300)

      result = run!

      expect(result.matched).to eq(0)
      expect(result.needs_review).to eq(1)

      t1.reload
      expect(t1.needs_manual_review?).to be(true)
      expect(t1.matched_till_deposit_id).to be_nil
    end

    it "does not consume any surplus deposits, leaving them available for manual selection" do
      deposit(amount: 300)
      deposit(amount: 300)
      transaction(amount: 300)

      run!

      expect(TillDeposit.where(amount: 300).count).to eq(2)
      expect(TillDeposit.where(amount: 300).where.missing(:bank_statement_transaction).count).to eq(2)
    end
  end

  # ── Matching priority ─────────────────────────────────────────────────────── #

  describe "reference number takes priority over amount/date" do
    it "matches by reference even when amounts differ slightly across candidates" do
      d_ref   = deposit(amount: 250, reference: "DEP-100")
      d_other = deposit(amount: 300)
      t1      = transaction(amount: 300, reference: "DEP-100")

      run!

      t1.reload
      expect(t1.matched_till_deposit_id).to eq(d_ref.id)
      expect(t1.matched_till_deposit_id).not_to eq(d_other.id)
      expect(t1.match_method).to eq("auto_reference")
      # Amount differs (250 vs 300) despite the reference match — flagged, not silently verified.
      expect(t1.status).to eq("amount_mismatch")
    end
  end

  describe "same amount, different references" do
    it "does not let reference numbers block an otherwise clean amount+date match" do
      d1 = deposit(amount: 300, reference: "A-1")
      t1 = transaction(amount: 300, reference: "B-2")

      run!

      t1.reload
      expect(t1.matched_till_deposit_id).to eq(d1.id)
      expect(t1.match_method).to eq("auto_amount_date")
      expect(t1.status).to eq("verified")
    end
  end

  describe "same amount, different dates" do
    it "matches within the ±1 day tolerance" do
      d1 = deposit(amount: 300, date: business_date + 1.day)
      t1 = transaction(amount: 300, date: business_date)

      run!

      t1.reload
      expect(t1.matched_till_deposit_id).to eq(d1.id)
      expect(t1.match_method).to eq("auto_amount_near_date")
      expect(t1.status).to eq("date_mismatch")
    end

    it "matches on amount only when the date gap exceeds 1 day" do
      d1 = deposit(amount: 300, date: business_date + 3.days)
      t1 = transaction(amount: 300, date: business_date)

      run!

      t1.reload
      expect(t1.matched_till_deposit_id).to eq(d1.id)
      expect(t1.match_method).to eq("auto_amount_only")
      expect(t1.status).to eq("date_mismatch")
    end
  end

  # ── No candidate at all ───────────────────────────────────────────────────── #

  describe "no candidate anywhere" do
    it "classifies as unexpected when nothing shares the amount or the date" do
      deposit(amount: 999, date: business_date + 10.days)
      t1 = transaction(amount: 300, date: business_date)

      run!

      t1.reload
      expect(t1.matched_till_deposit_id).to be_nil
      expect(t1.status).to eq("unexpected")
    end
  end

  # ── Determinism: re-import / rematch produces the identical result ───────── #

  describe "determinism (re-running matching against unchanged data)" do
    it "produces the identical pairing every time it is run" do
      d1 = deposit(amount: 300)
      d2 = deposit(amount: 300)
      d3 = deposit(amount: 300)
      t1 = transaction(amount: 300)
      t2 = transaction(amount: 300)
      t3 = transaction(amount: 300)

      first_run_result = run!
      first_pairing = [ t1, t2, t3 ].map { |t| t.reload.matched_till_deposit_id }

      expect(first_run_result.matched).to eq(3)

      # Rematch (as if the statement were re-imported / rematch triggered again).
      second_run_result = described_class.call(statement.id, actor: actor, rematch: true)
      second_pairing = [ t1, t2, t3 ].map { |t| t.reload.matched_till_deposit_id }

      expect(second_run_result.matched).to eq(3)
      expect(second_pairing).to eq(first_pairing)
      expect([ d1, d2, d3 ].map(&:id)).to match_array(first_pairing)
    end
  end

  # ── Audit trail ───────────────────────────────────────────────────────────── #

  describe "audit logging" do
    it "logs an auto_matched entry for every committed match" do
      deposit(amount: 300)
      t1 = transaction(amount: 300)

      expect { run! }.to change { AuditLog.for_auditable(t1).count }.by(1)
      expect(AuditLog.for_auditable(t1).last.action).to eq("auto_matched")
    end

    it "logs a needs_manual_review entry when a bucket is ambiguous" do
      deposit(amount: 300)
      deposit(amount: 300)
      t1 = transaction(amount: 300)

      expect { run! }.to change { AuditLog.for_auditable(t1).count }.by(1)
      expect(AuditLog.for_auditable(t1).last.action).to eq("needs_manual_review")
    end

    it "snapshots every candidate's amount/date/reference on a needs_manual_review entry" do
      d1 = deposit(amount: 300, reference: "A")
      d2 = deposit(amount: 300, reference: "B")
      t1 = transaction(amount: 300)

      run!

      candidates = AuditLog.for_auditable(t1).last.metadata["candidates"]
      expect(candidates.map { |c| c["till_deposit_id"] }).to match_array([ d1.id, d2.id ])
      expect(candidates.map { |c| c["reference"] }).to match_array(%w[A B])
    end
  end

  # ── Explainability: match_confidence / match_reason ──────────────────────── #

  describe "match_confidence and match_reason persistence" do
    it "persists the tier's score as match_confidence and a human-readable match_reason" do
      deposit(amount: 300, reference: "DEP-9")
      t1 = transaction(amount: 300, reference: "DEP-9")

      run!

      t1.reload
      expect(t1.match_confidence).to eq(described_class::SCORE_REFERENCE)
      expect(t1.match_reason).to include("DEP-9")
    end

    it "gives a lower confidence score to a ±1 day match than an exact-date match" do
      deposit(amount: 300, date: business_date + 1.day)
      t1 = transaction(amount: 300, date: business_date)

      run!

      t1.reload
      expect(t1.match_confidence).to eq(described_class::SCORE_AMOUNT_NEAR_DATE)
      expect(t1.match_confidence).to be < described_class::SCORE_AMOUNT_DATE
    end

    it "persists a confidence score and reason on a needs_manual_review outcome too" do
      deposit(amount: 300)
      deposit(amount: 300)
      t1 = transaction(amount: 300)

      run!

      t1.reload
      expect(t1.match_confidence).to eq(described_class::SCORE_AMOUNT_DATE)
      expect(t1.match_reason).to be_present
    end

    it "clears match_confidence and match_reason when there is no match at all" do
      t1 = transaction(amount: 999, date: business_date + 30.days)

      run!

      t1.reload
      expect(t1.match_confidence).to be_nil
      expect(t1.match_reason).to be_nil
    end
  end

  # ── Idempotency: rematch does not spam the audit trail ───────────────────── #

  describe "idempotent rematch" do
    it "does not add a new audit entry when a rematch reproduces the exact same outcome" do
      deposit(amount: 300)
      t1 = transaction(amount: 300)

      run!
      expect(AuditLog.for_auditable(t1).count).to eq(1)

      described_class.call(statement.id, actor: actor, rematch: true)

      expect(AuditLog.for_auditable(t1).count).to eq(1)
    end

    it "leaves the final matched state identical after a no-op rematch" do
      d1 = deposit(amount: 300)
      t1 = transaction(amount: 300)

      run!
      described_class.call(statement.id, actor: actor, rematch: true)

      t1.reload
      expect(t1.matched_till_deposit_id).to eq(d1.id)
      expect(t1.status).to eq("verified")
    end

    it "does add a new audit entry when a rematch actually changes the outcome" do
      # No deposit exists yet — the transaction has no candidate at all.
      t1 = transaction(amount: 300)
      run!
      t1.reload
      expect(t1.status).to eq("unexpected")
      expect(AuditLog.for_auditable(t1).count).to eq(0)

      # A matching deposit now appears (e.g. recorded after the statement was
      # imported); rematch should pick it up as a genuinely new outcome.
      d1 = deposit(amount: 300)
      described_class.call(statement.id, actor: actor, rematch: true)

      t1.reload
      expect(t1.matched_till_deposit_id).to eq(d1.id)
      expect(AuditLog.for_auditable(t1).count).to eq(1)
      expect(AuditLog.for_auditable(t1).last.action).to eq("auto_matched")
    end
  end
end
