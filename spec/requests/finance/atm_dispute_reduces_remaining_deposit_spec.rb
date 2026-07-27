require "rails_helper"

RSpec.describe "An open ATM Deposit Dispute reduces Remaining to Deposit everywhere", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, :owner, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 975, refund_amount: 0)
  end

  def atm_dispute(amount:, status: "new")
    BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: actor,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: amount, status: status, bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )
  end

  def transition!(dispute, to:)
    Finance::BankDisputes::StatusTransitioner.new(dispute.id, actor: actor, target_status: to).call
  end

  before { sign_in actor }

  it "shows the reduced expected amount and an explanatory notice on the Record Deposit dialog" do
    atm_dispute(amount: 200)

    get new_till_deposit_path(daily_reconciliation_id: dr.id)

    expect(response.body).to include(number_to_currency(775, unit: "", separator: ".", delimiter: ","))
    expect(response.body).to include(
      I18n.t("till_deposits.new.open_dispute_notice", amount: number_to_currency(200, unit: "", separator: ".", delimiter: ","))
    )
  end

  it "does not show the notice or reduce the expected amount when there is no open dispute" do
    get new_till_deposit_path(daily_reconciliation_id: dr.id)

    expect(response.body).to include(number_to_currency(975, unit: "", separator: ".", delimiter: ","))
    expect(response.body).not_to include("ATM Deposit Dispute")
  end

  it "rejects a deposit larger than what remains after the dispute is subtracted" do
    atm_dispute(amount: 200)

    post till_deposits_path, params: {
      till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                      amount: "800.00", deposited_at: Time.current.to_s }
    }

    expect(TillDeposit.count).to eq(0)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(flash[:alert]).to eq(I18n.t("till_deposits.errors.exceeds_remaining", remaining: "775.0"))
  end

  it "accepts exactly the reduced remaining amount" do
    atm_dispute(amount: 200)

    post till_deposits_path, params: {
      till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                      amount: "775.00", deposited_at: Time.current.to_s }
    }

    expect(TillDeposit.count).to eq(1)
    expect(dr.reload.pending_deposit_amount).to eq(0)
  end

  it "returns the amount to Remaining to Deposit once the dispute is rejected, and the dialog reflects it live" do
    dispute = atm_dispute(amount: 200)
    expect(dr.pending_deposit_amount).to eq(775)

    transition!(dispute, to: "submitted_to_bank")
    transition!(dispute, to: "under_investigation")
    transition!(dispute, to: "rejected")

    expect(dr.reload.pending_deposit_amount).to eq(975)

    get new_till_deposit_path(daily_reconciliation_id: dr.id)
    expect(response.body).to include(number_to_currency(975, unit: "", separator: ".", delimiter: ","))
  end

  it "converting a confirmed_successful dispute into a real TillDeposit removes it from Remaining to Deposit" do
    dispute = atm_dispute(amount: 200)
    transition!(dispute, to: "submitted_to_bank")
    transition!(dispute, to: "under_investigation")
    transition!(dispute, to: "confirmed_successful")

    # Between confirmation and conversion the dispute is resolved (no longer
    # "open"), so it briefly stops reducing remaining — the conversion below
    # is what actually re-covers it via a real TillDeposit.
    expect(dr.reload.pending_deposit_amount).to eq(975)

    patch confirm_deposit_finance_bank_dispute_path(dispute), params: { payment_method_id: cash_pm.id }

    dispute.reload
    expect(dispute.status).to eq("closed")
    expect(dispute.till_deposit).to be_present
    expect(dr.reload.pending_deposit_amount).to eq(775)
    expect(dr.total_deposited).to eq(200)
  end

  it "keeps a closed dispute archived without affecting financial totals" do
    dispute = atm_dispute(amount: 200)
    transition!(dispute, to: "submitted_to_bank")
    transition!(dispute, to: "under_investigation")
    transition!(dispute, to: "rejected")
    expect(dr.reload.pending_deposit_amount).to eq(975)

    transition!(dispute, to: "closed")

    expect(dr.reload.pending_deposit_amount).to eq(975)
  end

  private

  def number_to_currency(amount, **opts)
    ApplicationController.helpers.number_to_currency(amount, **opts)
  end
end
