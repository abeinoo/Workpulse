require "rails_helper"

# Financial-correctness guard for the second performance pass: every
# aggregate method that now branches on `association.loaded?` (added to
# avoid re-querying an already-eager-loaded association — see
# DailyReconciliation and TillHandover) must return EXACTLY the same value
# whether or not its association happens to be preloaded. This spec builds
# one richly-populated DR and asserts both code paths agree, for every
# method that was touched.
RSpec.describe "DailyReconciliation / TillHandover — preloaded vs unloaded parity", type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:card_pm)  { PaymentMethod.create!(business: business, name: "Card", settlement_type: "card", active: true) }
  let(:actor)    { create(:user, business: business) }
  let(:other)    { create(:user, business: business) }

  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "closed",
                                 opened_at: 1.day.ago, business_date: Date.current)
  end

  before do
    TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm,
                               payment_method_name: cash_pm.name, collected_amount: 500, refund_amount: 20)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: card_pm,
                               payment_method_name: card_pm.name, collected_amount: 300, refund_amount: 0)

    @dep1 = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                                 amount: 200, deposited_at: Time.current)
    @dep2 = TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm, deposited_by: actor,
                                 amount: 80, deposited_at: Time.current, void_reason: "duplicate",
                                 voided_at: Time.current, voided_by: actor)

    stmt = create(:bank_statement, business: business, branch: branch,
                   statement_from: Date.current, statement_to: Date.current)
    txn = BankStatementTransaction.create!(bank_statement: stmt, business: business,
                                            transaction_date: Date.current, amount: 200,
                                            raw_data: {}, status: "unexpected")
    DepositMatch.create_for!(till_deposit: @dep1, bank_statement_transaction: txn, matched_by: actor)
    txn.update!(status: "verified")

    RemainingDepositBalance.create!(daily_reconciliation: dr, till_deposit: @dep1, responsible_user: actor,
                                     created_by: actor, business: business, branch: branch,
                                     amount: 20, remaining_amount: 20, status: "open")

    BankDispute.create!(daily_reconciliation: dr, kind: "atm_deposit_failure", amount: 15,
                         status: "new", opened_by: actor, business: business, branch: branch,
                         opened_at: Time.current, bank_name: "Test Bank", terminal_id: "TERM-1",
                         transaction_date: Date.current, card_last4: "1234")
  end

  # Fetches the SAME DR either with the relevant associations preloaded
  # (exercising the `loaded?` branch) or completely fresh (exercising the
  # original DB-query branch).
  def loaded_dr
    DailyReconciliation.includes(:till_deposits, :bank_disputes, session_amounts: [], remaining_deposit_balances: [])
                        .find(dr.id)
  end

  def unloaded_dr
    DailyReconciliation.find(dr.id)
  end

  it "total_deposited agrees whether till_deposits is preloaded or not" do
    expect(loaded_dr.total_deposited).to eq(unloaded_dr.total_deposited)
    expect(loaded_dr.total_deposited).to eq(200) # only the active (non-voided) deposit counts
  end

  it "expected_cash_deposit agrees whether session_amounts is preloaded or not" do
    loaded = DailyReconciliation.includes(session_amounts: :payment_method).find(dr.id)
    expect(loaded.expected_cash_deposit).to eq(unloaded_dr.expected_cash_deposit)
    expect(loaded.expected_cash_deposit).to eq(480) # 500 collected - 20 refund, cash only
  end

  it "total_remaining_balance agrees whether remaining_deposit_balances is preloaded or not" do
    expect(loaded_dr.total_remaining_balance).to eq(unloaded_dr.total_remaining_balance)
    expect(loaded_dr.total_remaining_balance).to eq(20)
  end

  it "total_matched_amount agrees whether till_deposits/deposit_matches is preloaded or not" do
    loaded = DailyReconciliation.includes(till_deposits: :deposit_matches).find(dr.id)
    expect(loaded.total_matched_amount).to eq(unloaded_dr.total_matched_amount)
    expect(loaded.total_matched_amount).to eq(200)
  end

  it "open_atm_dispute_amount agrees whether bank_disputes is preloaded or not" do
    expect(loaded_dr.open_atm_dispute_amount).to eq(unloaded_dr.open_atm_dispute_amount)
    expect(loaded_dr.open_atm_dispute_amount).to eq(15)
  end

  it "bank_reconciliation_status agrees whether till_deposits is preloaded or not" do
    loaded = DailyReconciliation.includes(till_deposits: [ :deposit_matches, :bank_statement_transactions ]).find(dr.id)
    expect(loaded.bank_reconciliation_status).to eq(unloaded_dr.bank_reconciliation_status)
  end

  it "bank_statement_imported? agrees whether till_deposits is preloaded or not" do
    loaded = DailyReconciliation.includes(till_deposits: :bank_statement_transactions).find(dr.id)
    expect(loaded.bank_statement_imported?).to eq(unloaded_dr.bank_statement_imported?)
  end

  describe "TillHandover#effective_operational_amounts" do
    let(:handover) do
      h = TillHandover.create!(daily_reconciliation: dr, from_user: actor, self_deposit: true)
      TillHandoverAmount.create!(till_handover: h, payment_method: cash_pm, payment_method_name: cash_pm.name,
                                  collected_amount: 500, refund_amount: 20)
      TillHandoverAmount.create!(till_handover: h, payment_method: card_pm, payment_method_name: card_pm.name,
                                  collected_amount: 300, refund_amount: 0)
      h
    end

    def with_override(h)
      FinancialAdjustment.create!(
        adjustable: h, business: business, actor: actor, reason_code: "count_correction",
        notes: "recount after the drawer audit found a discrepancy",
        before_data: { payment_method_id: cash_pm.id, collected_amount: "500" },
        after_data:  [ { "payment_method_id" => cash_pm.id, "collected_amount" => "550", "refund_amount" => "20" } ]
      )
      h
    end

    it "agrees whether amounts/financial_adjustments are preloaded or not (no override)" do
      handover
      loaded   = TillHandover.includes(:financial_adjustments, amounts: :payment_method).find(handover.id)
      unloaded = TillHandover.find(handover.id)

      expect(loaded.effective_operational_amounts.sort_by { |a| a[:payment_method_id] })
        .to eq(unloaded.effective_operational_amounts.sort_by { |a| a[:payment_method_id] })
    end

    it "agrees whether amounts/financial_adjustments are preloaded or not (with an override applied)" do
      with_override(handover)
      loaded   = TillHandover.includes(:financial_adjustments, amounts: :payment_method).find(handover.id)
      unloaded = TillHandover.find(handover.id)

      loaded_amounts   = loaded.effective_operational_amounts.sort_by { |a| a[:payment_method_id] }
      unloaded_amounts = unloaded.effective_operational_amounts.sort_by { |a| a[:payment_method_id] }
      expect(loaded_amounts).to eq(unloaded_amounts)

      cash_row = loaded_amounts.find { |a| a[:payment_method_id] == cash_pm.id }
      expect(cash_row[:collected_amount]).to eq(550) # the override, not the original 500
    end
  end
end
