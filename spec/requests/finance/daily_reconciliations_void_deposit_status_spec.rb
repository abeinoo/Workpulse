require "rails_helper"

RSpec.describe "Finance::DailyReconciliations — status after voiding a deposit", type: :request do
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
                              collected_amount: 5_000, refund_amount: 0)
  end

  before { sign_in actor }

  def record_deposit(amount)
    Finance::TillDepositRecorder.new(
      dr.id, actor: actor,
      params: { payment_method_id: cash_pm.id, amount: amount.to_s, deposited_at: Time.current.to_s }
    ).call
  end

  describe "voiding the only active deposit, end to end via the controller" do
    it "reverts the DR out of the deposited state" do
      result = record_deposit(5_000)
      expect(dr.reload.state).to eq("deposited")

      patch void_till_deposit_path(result.deposit), params: { void_reason: "Wrong amount" }

      expect(dr.reload.state).to eq("closed")
    end

    it "show page no longer renders the Deposited status badge, and total deposits/count reset to zero" do
      result = record_deposit(5_000)
      patch void_till_deposit_path(result.deposit), params: { void_reason: "Wrong amount" }

      get finance_daily_reconciliation_path(dr)

      doc = Nokogiri::HTML(response.body)
      status_label = doc.css(".stat-card__label").find { |n| n.text.strip == "Overall Status" }
      status_value = status_label.parent.at_css(".stat-card__value").text.strip

      expect(status_value).to eq("Closed")
      expect(dr.reload.total_deposited).to eq(0)
    end

    it "index page no longer counts this DR as deposited or shows it as Waiting for Accounting Approval" do
      result = record_deposit(5_000)

      get finance_daily_reconciliations_path
      expect(response.body).to include("Waiting for Accounting Approval")

      patch void_till_deposit_path(result.deposit), params: { void_reason: "Wrong amount" }

      get finance_daily_reconciliations_path
      expect(response.body).not_to include("Waiting for Accounting Approval")
    end

    it "keeps the DR deposited when a second active deposit still exists" do
      other_pm = PaymentMethod.create!(business: business, name: "Cash USD", settlement_type: "cash", active: true)
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: other_pm,
                                payment_method_name: "Cash USD", collected_amount: 100, refund_amount: 0)
      Finance::TillDepositRecorder.new(
        dr.id, actor: actor,
        params: { payment_method_id: other_pm.id, amount: "100.00", deposited_at: Time.current.to_s }
      ).call

      result = record_deposit(5_000)
      patch void_till_deposit_path(result.deposit), params: { void_reason: "Wrong amount" }

      expect(dr.reload.state).to eq("deposited")
    end
  end
end
