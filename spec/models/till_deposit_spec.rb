require "rails_helper"

RSpec.describe TillDeposit, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
      )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let(:statement)     { create(:bank_statement, business: business, branch: branch) }

  def deposit(amount: 11_700)
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                        amount: amount, deposited_at: Time.current)
  end

  def txn(amount)
    create(:bank_statement_transaction, business: business, bank_statement: statement, amount: amount)
  end

  def link!(dep, transaction)
    DepositMatch.create_for!(till_deposit: dep, bank_statement_transaction: transaction)
  end

  describe "#match_status / #matched_total" do
    it "is :unmatched with no matches" do
      dep = deposit
      expect(dep.match_status).to eq(:unmatched)
      expect(dep.matched_total).to eq(0)
    end

    it "is :fully_matched when one transaction equals the deposit amount" do
      dep = deposit(amount: 500)
      link!(dep, txn(500))

      expect(dep.match_status).to eq(:fully_matched)
      expect(dep.matched_total).to eq(500)
    end

    it "is :fully_matched when multiple transactions sum exactly to the deposit amount" do
      dep = deposit(amount: 11_700)
      link!(dep, txn(7_000))
      link!(dep, txn(4_700))

      expect(dep.match_status).to eq(:fully_matched)
      expect(dep.matched_total).to eq(11_700)
    end

    it "is :partially_matched when the total is less than the deposit amount" do
      dep = deposit(amount: 11_700)
      link!(dep, txn(7_000))

      expect(dep.match_status).to eq(:partially_matched)
      expect(dep.matched_total).to eq(7_000)
    end

    it "is :over_matched when the total exceeds the deposit amount" do
      dep = deposit(amount: 11_700)
      link!(dep, txn(7_000))
      link!(dep, txn(5_000))

      expect(dep.match_status).to eq(:over_matched)
      expect(dep.matched_total).to eq(12_000)
    end
  end

  describe ".not_fully_matched" do
    it "includes deposits with no matches and partial matches, excludes fully matched ones" do
      unmatched = deposit(amount: 500)
      partial   = deposit(amount: 11_700)
      link!(partial, txn(7_000))
      full = deposit(amount: 500)
      link!(full, txn(500))

      results = TillDeposit.not_fully_matched.to_a
      expect(results).to include(unmatched, partial)
      expect(results).not_to include(full)
    end

    # The manual-match modal's composition: there, includes resolves to a JOIN-based
    # eager load, so every included table's columns enter the SELECT.
    # A GROUP BY in the scope made PostgreSQL reject that (PG::GroupingError on
    # daily_reconciliations.id).
    it "composes with eager-loaded joined tables, once per deposit" do
      partial = deposit(amount: 11_700)
      link!(partial, txn(7_000))
      link!(partial, txn(2_000))

      results = TillDeposit.joins(:daily_reconciliation)
                           .where(daily_reconciliations: { business_id: partial.daily_reconciliation.business_id })
                           .not_fully_matched
                           .eager_load(:payment_method, :deposited_by, daily_reconciliation: :branch)
                           .order(deposited_at: :desc)

      expect { results.to_a }.not_to raise_error
      expect(results.to_a.map(&:id)).to eq([ partial.id ])
    end
  end
end
