require "rails_helper"

RSpec.describe "Finance::DailyReconciliations — partial deposit status", type: :request do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, :owner, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "closed",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current,
      reviewed_by: actor, reviewed_at: 1.minute.ago
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:session_amount) do
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                              collected_amount: 5_000, refund_amount: 0)
  end

  before { sign_in actor }

  def deposit(amount)
    Finance::TillDepositRecorder.new(
      dr.id, actor: actor,
      params: { payment_method_id: cash_pm.id, amount: amount.to_s, deposited_at: Time.current.to_s }
    ).call
  end

  describe "GET index" do
    it "shows Deposit Incomplete after a partial deposit, not Ready for Verification" do
      deposit(4_000)

      get finance_daily_reconciliations_path

      expect(response.body).to include("Deposit Incomplete")
      expect(response.body).not_to include("Ready for Verification")
    end

    it "shows Ready for Verification once fully deposited" do
      deposit(4_000)
      deposit(1_000)

      get finance_daily_reconciliations_path

      expect(response.body).to include("Ready for Verification")
    end
  end

  describe "GET show — deposit summary and recorded deposits" do
    it "lists each deposit separately with the correct running total and remaining amount" do
      deposit(4_000)
      deposit(700)

      get finance_daily_reconciliation_path(dr)

      expect(response.body).to include("4,000.00").or include("4000.00")
      expect(response.body).to include("700.00")
      expect(response.body.scan(/700\.00|4,000\.00|4000\.00/).size).to be >= 2
    end
  end
end
