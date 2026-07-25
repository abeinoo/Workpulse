require "rails_helper"

RSpec.describe "Record Deposit / Report ATM Deposit Issue happen BEFORE Branch Review", type: :request do
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
  def report_atm_text     = I18n.t("till_deposits.new.report_atm_problem")

  describe "immediately after the cashier closes the session (no review needed yet)" do
    it "shows both actions on the DR show page" do
      expect(dr.reviewed?).to be false

      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(record_deposit_text)
      expect(response.body).to include(report_atm_text)
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

  describe "once the Branch Manager has approved the recorded deposit (locked)" do
    before do
      dr.till_deposits.create!(payment_method: cash_pm, deposited_by: employee, amount: 300, deposited_at: Time.current)
      dr.update_columns(state: "deposited")
      dr.update!(reviewed_by: employee, reviewed_at: Time.current)
    end

    it "hides Record Deposit on the DR show page for an ordinary depositor" do
      get finance_daily_reconciliation_path(dr)

      expect(response.body).not_to include(record_deposit_text)
    end

    it "still shows Report ATM Deposit Issue — it is never locked by deposit approval" do
      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include(report_atm_text)
    end

    it "blocks recording a further deposit via the policy gate (not just hidden UI)" do
      get new_till_deposit_path(daily_reconciliation_id: dr.id)
      expect(response).to redirect_to(root_path)
    end

    it "allows a further/corrected deposit for a user holding override_review_requirement" do
      overrider = user_with("view_daily_reconciliation", "close_till_session", "create_till_deposit", "override_review_requirement")
      till_session.update!(depositor_id: overrider.id)
      sign_in overrider

      get new_till_deposit_path(daily_reconciliation_id: dr.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(I18n.t("till_deposits.new.deposit_locked_title"))
    end
  end
end
