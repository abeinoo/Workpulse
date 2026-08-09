require "rails_helper"

# Covers the Daily Reconciliations INDEX card's "Settle Remaining" action for
# an open RemainingDepositBalance — including the case where the balance
# originated from a confirmed bank dispute that was registered as a real
# TillDeposit (Finance::BankDisputes::DepositConfirmer ->
# Finance::TillDepositRecorder). No new settlement mechanism is introduced —
# the card link reuses the exact same finance_remaining_deposit_balance_path
# route/controller/form the DR show page's own outstanding-balance link uses.
RSpec.describe "Finance::DailyReconciliations index — Settle Remaining action", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def build_dr(expected_amount:)
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
    TillSession.create!(daily_reconciliation: dr, depositor_id: owner.id)
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: expected_amount, refund_amount: 0)
    dr
  end

  def open_atm_dispute(dr, amount:)
    BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: owner,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: amount, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )
  end

  def confirm_successful!(dispute)
    %w[submit_to_bank start_investigation confirm_successful].each do |route|
      patch "/finance/bank_disputes/#{dispute.id}/#{route}", params: {}
      dispute.reload
    end
    expect(dispute.status).to eq("confirmed_successful")
  end

  def register_dispute_as_deposit!(dispute, payment_method: cash_pm)
    patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: payment_method.id }
    dispute.reload
  end

  before { sign_in owner }

  it "shows Settle Remaining (not Record Deposit) once a confirmed dispute has been registered as a deposit, for the exact 12,815 / 12,750 / 65 scenario" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)
    dr.reload

    expect(dr.total_deposited).to eq(12_750)
    expect(dr.open_atm_dispute_amount).to eq(0)
    expect(dr.total_remaining_balance).to eq(65)

    get finance_daily_reconciliations_path
    expect(response).to have_http_status(:ok)

    doc = Nokogiri::HTML(response.body)
    card = doc.at_css(".dr-card")
    rdb = dr.remaining_deposit_balances.open.sole

    expect(card.text).to include(I18n.t("finance.daily_reconciliations.index.workspace.workflow.settle_action"))
    # The step checklist still lists "Record Deposit" with its ✓ checkmark
    # (state is now "deposited"), but there must be no actionable link back
    # into the deposit-recording form anymore — only the Settle Remaining link.
    deposit_action_link = card.at_css("a[href='#{new_till_deposit_path(daily_reconciliation_id: dr.id)}']")
    expect(deposit_action_link).to be_nil

    settle_link = card.at_css("a[href='#{finance_remaining_deposit_balance_path(rdb)}']")
    expect(settle_link).to be_present
  end

  it "keeps showing Settle Remaining after a partial settlement, and drops it once fully settled" do
    dr = build_dr(expected_amount: 12_815)
    dispute = open_atm_dispute(dr, amount: 12_750)
    confirm_successful!(dispute)
    register_dispute_as_deposit!(dispute)
    rdb = dr.remaining_deposit_balances.open.sole

    Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: owner, amount: 30).call
    expect(rdb.reload.remaining_amount).to eq(35)

    get finance_daily_reconciliations_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css(".dr-card").text).to include(I18n.t("finance.daily_reconciliations.index.workspace.workflow.settle_action"))
    expect(doc.at_css(".dr-card").text).to include("35")

    Finance::RemainingDepositBalanceSettler.new(rdb.id, actor: owner, amount: 35).call
    expect(rdb.reload.remaining_amount).to eq(0)
    expect(rdb.status).to eq("settled")

    get finance_daily_reconciliations_path
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css(".dr-card").text).not_to include(I18n.t("finance.daily_reconciliations.index.workspace.workflow.settle_action"))
  end

  it "does not show Settle Remaining for a normal reconciliation with no shortfall" do
    build_dr(expected_amount: 500)

    get finance_daily_reconciliations_path
    doc = Nokogiri::HTML(response.body)

    expect(doc.at_css(".dr-card").text).not_to include(I18n.t("finance.daily_reconciliations.index.workspace.workflow.settle_action"))
  end

  it "shows Settle Remaining for an ordinary short cash deposit with no bank dispute involved" do
    dr = build_dr(expected_amount: 500)
    Finance::TillDepositRecorder.new(
      dr.id, actor: owner, params: { payment_method_id: cash_pm.id, amount: 470, deposited_at: Time.current }
    ).call
    rdb = dr.reload.remaining_deposit_balances.open.sole
    expect(rdb.remaining_amount).to eq(30)

    get finance_daily_reconciliations_path
    doc = Nokogiri::HTML(response.body)
    card = doc.at_css(".dr-card")

    expect(card.text).to include(I18n.t("finance.daily_reconciliations.index.workspace.workflow.settle_action"))
    settle_link = card.at_css("a[href='#{finance_remaining_deposit_balance_path(rdb)}']")
    expect(settle_link).to be_present
  end
end
