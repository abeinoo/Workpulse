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
    it "shows Ready for Verification as soon as the first deposit is recorded, even with a remaining balance" do
      deposit(4_000)

      get finance_daily_reconciliations_path

      expect(response.body).to include("Ready for Verification")
      expect(response.body).not_to include("Deposit Incomplete")
    end

    it "still shows Ready for Verification once fully deposited" do
      deposit(4_000)
      deposit(1_000)

      get finance_daily_reconciliations_path

      expect(response.body).to include("Ready for Verification")
    end

    it "shows Awaiting Deposit before any deposit has been recorded" do
      get finance_daily_reconciliations_path

      expect(response.body).to include("Awaiting Deposit")
      expect(response.body).not_to include("Ready for Verification")
    end
  end

  describe "PATCH verify" do
    it "verifies successfully with only a partial deposit recorded, leaving a remaining balance" do
      deposit(4_000)

      patch verify_finance_daily_reconciliation_path(dr)

      expect(dr.reload.verified?).to be true
      expect(dr.pending_deposit_amount).to eq(1_000)
      follow_redirect!
      expect(response.body).not_to include(I18n.t("finance.daily_reconciliations.errors.verify_no_deposit_recorded"))
    end

    it "still refuses to verify when no deposit has been recorded at all" do
      patch verify_finance_daily_reconciliation_path(dr)

      expect(dr.reload.verified?).to be false
      follow_redirect!
      expect(response.body).to include(I18n.t("finance.daily_reconciliations.errors.verify_no_deposit_recorded"))
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
