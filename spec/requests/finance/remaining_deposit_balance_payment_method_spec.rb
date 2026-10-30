require "rails_helper"

# BUG-032 — the settle action refuses a foreign or missing payment method with
# an explanation (it used to 500 on a missing id) and writes nothing.
RSpec.describe "PATCH settle a remaining deposit balance with an invalid payment method (BUG-032)", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let(:branch)   { create(:branch, business: business) }
  let(:dr) do
    DailyReconciliation.create!(branch: branch, business: business, state: "closed", opened_at: 1.hour.ago,
                                closed_at: Time.current, business_date: Date.current)
  end
  let!(:balance) do
    RemainingDepositBalance.create!(daily_reconciliation: dr, responsible_user: owner, created_by: owner,
                                    business: business, branch: branch, amount: 200, remaining_amount: 200,
                                    status: "open")
  end
  let(:foreign) { PaymentMethod.create!(business: create(:business), name: "Wallet", settlement_type: "cash", active: true) }

  before { sign_in owner }

  [ -> { foreign.id }, -> { PaymentMethod.maximum(:id).to_i + 1000 } ].each_with_index do |id, index|
    it "refuses it with an explanation instead of an error page (#{%w[foreign missing][index]})" do
      expect {
        patch settle_finance_remaining_deposit_balance_path(balance),
              params: { amount: 50, payment_method_id: instance_exec(&id) }
      }.not_to change(RemainingDepositBalanceTransaction, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include(CGI.escapeHTML(I18n.t("remaining_deposit_balances.errors.invalid_payment_method")))
      expect(balance.reload.remaining_amount).to eq(200)
    end
  end
end
