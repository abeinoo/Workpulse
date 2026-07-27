require "rails_helper"

RSpec.describe "Deposit Responsibility Transfer show page uses the shared remaining calculation", type: :request do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:from_user) { create(:user, :owner, business: business) }
  let(:to_user)   { create(:user, business: business) }

  let(:cash_pm_a) { PaymentMethod.create!(business: business, name: "Cash A", settlement_type: "cash", active: true, position: 1) }
  let(:cash_pm_b) { PaymentMethod.create!(business: business, name: "Cash B", settlement_type: "cash", active: true, position: 2) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: from_user.id) }
  let!(:session_amount_a) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm_a, payment_method_name: "Cash A",
                              collected_amount: 325, refund_amount: 0)
  end
  let!(:session_amount_b) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm_b, payment_method_name: "Cash B",
                              collected_amount: 1_650, refund_amount: 0)
  end
  let!(:deposit_b) do
    TillDeposit.create!(daily_reconciliation: dr, payment_method: cash_pm_b, deposited_by: from_user,
                        amount: 1_000, deposited_at: Time.current)
  end
  let!(:transfer) { DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: from_user, to_user: to_user) }

  before { sign_in to_user }

  it "shows totals matching DailyReconciliation#pending_deposit_amount, not an independent recalculation" do
    BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: from_user,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: 200, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )

    get deposit_responsibility_transfer_path(transfer)

    expect(response).to have_http_status(:ok)
    expect(dr.pending_deposit_amount).to eq(775)
    expect(response.body).to include(format_currency(775))
  end

  it "matches remaining_by_payment_method's proportional split per row, without a locally recomputed figure" do
    BankDispute.create!(
      daily_reconciliation: dr, business: business, branch: branch, opened_by: from_user,
      opened_at: Time.current, transaction_date: Date.current, kind: "atm_deposit_failure",
      amount: 200, status: "new", bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
    )
    expected = dr.remaining_by_payment_method

    get deposit_responsibility_transfer_path(transfer)

    expect(response.body).to include(format_currency(expected[cash_pm_a.id]))
    expect(response.body).to include(format_currency(expected[cash_pm_b.id]))
  end

  it "shows the full remaining amount with no discount when there is no open dispute" do
    get deposit_responsibility_transfer_path(transfer)

    expect(response.body).to include(format_currency(975))
  end

  private

  def format_currency(amount)
    ApplicationController.helpers.number_to_currency(amount, unit: "", separator: ".", delimiter: ",")
  end
end
