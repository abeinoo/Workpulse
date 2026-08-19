require "rails_helper"

RSpec.describe "Record Deposit / Report ATM Deposit Issue — no Deposit Review approval gate", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  def user_with(*perms)
    role = business.permission_roles.create!(
      name: "R-#{SecureRandom.hex(3)}",
      permissions: perms,
      permission_scopes: perms.index_with { "business_wide" }
    )
    create(:user, business: business).tap { |u| u.update_column(:permission_role_id, role.id) }
  end

  let(:employee) { user_with("close_till_session", "create_till_deposit", "view_daily_reconciliation", "view_deposit_verification") }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: employee.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 300, refund_amount: 0)
  end

  before { sign_in employee }

  def record_deposit_text = I18n.t("finance.daily_reconciliations.show.action_deposit")

  describe "immediately after the cashier closes the session" do
    it "shows the Record Deposit action on the DR show page" do
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(record_deposit_text)
    end

    it "shows the Record Deposit quick action on the index card" do
      get finance_daily_reconciliations_path

      expect(response.body).to include(record_deposit_text)
    end

    it "the deposit workflow functions end to end, advancing the DR to deposited" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                        amount: "300.00", deposited_at: Time.current.to_s }
      }

      expect(dr.reload.total_deposited).to eq(300)
      expect(dr.state).to eq("deposited")
    end

    it "the ATM dispute workflow functions end to end" do
      post finance_bank_disputes_path, params: {
        bank_dispute: {
          daily_reconciliation_id: dr.id, transaction_date: Date.current.to_s, transaction_time: "14:00",
          amount: 300, bank_name: "NBE", terminal_id: "ATM-1", card_last4: "1234"
        }
      }

      dispute = BankDispute.last
      expect(dispute.kind).to eq("atm_deposit_failure")
      expect(response).to redirect_to(finance_bank_dispute_path(dispute))
    end
  end

  describe "once the deposit is recorded (deposited state) — still no approval step in the way" do
    before do
      dr.till_deposits.create!(payment_method: cash_pm, deposited_by: employee, amount: 300, deposited_at: Time.current)
      dr.update_columns(state: "deposited")
    end

    it "still shows Record Deposit on the DR show page — a Daily Reconciliation may accumulate multiple deposits" do
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(record_deposit_text)
    end

    it "the ATM dispute endpoint remains reachable" do
      get new_finance_bank_dispute_path(daily_reconciliation_id: dr.id)

      expect(response).to have_http_status(:ok)
    end

    it "allows recording a further deposit via the policy gate" do
      get new_till_deposit_path(daily_reconciliation_id: dr.id)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "once the DR is verified — deposits are locked" do
    before do
      dr.till_deposits.create!(payment_method: cash_pm, deposited_by: employee, amount: 300, deposited_at: Time.current)
      dr.update!(state: "verified", verified_by: employee, verified_at: Time.current)
    end

    it "blocks recording a further deposit via the policy gate (not just hidden UI)" do
      get new_till_deposit_path(daily_reconciliation_id: dr.id)
      expect(response).to redirect_to(root_path)
    end
  end
end
