require "rails_helper"

RSpec.describe Finance::RemainingDepositBalanceSettler, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

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

  let(:balance) do
    RemainingDepositBalance.create!(
      daily_reconciliation: dr,
      responsible_user:     actor,
      created_by:           actor,
      business:             business,
      branch:               branch,
      amount:               200,
      remaining_amount:     200,
      status:               "open"
    )
  end

  # Helper so every example can call the service identically.
  def settle(balance_id:, amount:, notes: "test settlement")
    Finance::RemainingDepositBalanceSettler.new(
      balance_id,
      actor:  actor,
      amount: amount,
      notes:  notes
    ).call
  end

  # ── Contract: the service receives an Integer ID ──────────────────────────────

  describe "service contract" do
    it "accepts an integer ID and resolves the record internally" do
      result = settle(balance_id: balance.id, amount: 50)
      expect(result).to be_ok
    end

    it "raises ArgumentError when passed an AR object instead of an ID" do
      # Guard against callers accidentally passing the loaded object (the bug
      # that surfaced in bulk settle).  ActiveRecord::Base#find raises when
      # given an AR instance, and the service must not silently absorb that.
      expect {
        Finance::RemainingDepositBalanceSettler.new(
          balance,          # AR object — wrong contract
          actor:  actor,
          amount: 50
        ).call
      }.to raise_error(ArgumentError, /ActiveRecord::Base/)
    end
  end

  # ── Partial settlement ────────────────────────────────────────────────────────

  describe "partial settlement" do
    it "reduces remaining_amount and keeps status open" do
      result = settle(balance_id: balance.id, amount: 80)

      expect(result).to be_ok
      expect(result.balance.remaining_amount).to eq(120)
      expect(result.balance).to be_open
      expect(result.balance.closed_at).to be_nil
    end

    it "appends a settlement transaction to the ledger" do
      expect { settle(balance_id: balance.id, amount: 80) }
        .to change { balance.balance_transactions.count }.by(1)

      txn = balance.balance_transactions.last
      expect(txn.transaction_type).to eq("settlement")
      expect(txn.amount).to eq(80)
    end
  end

  # ── Full settlement ───────────────────────────────────────────────────────────

  describe "full settlement" do
    it "zeroes remaining_amount, marks status settled, and sets closed_at" do
      result = settle(balance_id: balance.id, amount: 200)

      expect(result).to be_ok
      expect(result.balance.remaining_amount).to eq(0)
      expect(result.balance).to be_settled
      expect(result.balance.closed_at).to be_present
    end
  end

  # ── Guard conditions ──────────────────────────────────────────────────────────

  describe "guard conditions" do
    it "returns an error when the balance is already settled" do
      balance.update!(status: "settled", remaining_amount: 0, closed_at: Time.current)

      result = settle(balance_id: balance.id, amount: 50)
      expect(result).not_to be_ok
      expect(result.error).to be_present
    end

    it "returns an error when amount is zero" do
      result = settle(balance_id: balance.id, amount: 0)
      expect(result).not_to be_ok
    end

    it "returns an error when amount exceeds remaining balance" do
      result = settle(balance_id: balance.id, amount: 999)
      expect(result).not_to be_ok
    end

    it "raises ActiveRecord::RecordNotFound when the balance belongs to another business" do
      other_business = create(:business)
      other_actor    = create(:user, business: other_business)
      other_branch   = create(:branch, business: other_business)
      other_dr       = DailyReconciliation.create!(
        branch:        other_branch,
        business:      other_business,
        state:         "closed",
        opened_at:     1.hour.ago,
        closed_at:     Time.current,
        business_date: Date.current
      )
      foreign_balance = RemainingDepositBalance.create!(
        daily_reconciliation: other_dr,
        responsible_user:     other_actor,
        created_by:           other_actor,
        business:             other_business,
        branch:               other_branch,
        amount:               100,
        remaining_amount:     100,
        status:               "open"
      )

      # The service scopes to actor.business_id, so a cross-business ID must not resolve.
      expect {
        settle(balance_id: foreign_balance.id, amount: 50)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
