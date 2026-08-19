require "rails_helper"

RSpec.describe "Bank deposit correction workflow — record, void, correct", type: :request do
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
                              collected_amount: 17_900, refund_amount: 0)
  end

  before { sign_in actor }

  describe "Record Deposit" do
    it "creates a TillDeposit and advances the DR to deposited" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "15750.00", deposited_at: Time.current.to_s }
      }

      expect(response).to redirect_to(finance_daily_reconciliation_path(dr))
      expect(TillDeposit.count).to eq(1)
      expect(dr.reload.state).to eq("deposited")
    end
  end

  describe "Void Deposit" do
    it "voids the deposit and reverts the DR out of the deposited state" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "15750.00", deposited_at: Time.current.to_s }
      }
      wrong_deposit = TillDeposit.last

      patch void_till_deposit_path(wrong_deposit), params: { void_reason: "Wrong amount entered" }

      expect(wrong_deposit.reload.voided?).to be true
      expect(dr.reload.state).to eq("closed")
      expect(dr.total_deposited).to eq(0)
    end
  end

  describe "Correct Deposit" do
    it "shows the Correct Deposit action on the voided deposit and pre-fills the new-deposit form from it" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "15750.00", reference: "ATM-001", deposited_at: Time.current.to_s }
      }
      wrong_deposit = TillDeposit.last
      patch void_till_deposit_path(wrong_deposit), params: { void_reason: "Wrong amount entered" }

      get finance_daily_reconciliation_path(dr)
      expect(response.body).to include(t_bank("correct_deposit_action"))

      get new_till_deposit_path(daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                                prefill_amount: wrong_deposit.amount, prefill_reference: wrong_deposit.reference)
      expect(response.body).to include('value="15750.0"').or include('value="15750"')
      expect(response.body).to include('value="ATM-001"')
    end

    it "creates a brand new TillDeposit without ever modifying the voided one" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "15750.00", deposited_at: Time.current.to_s }
      }
      wrong_deposit = TillDeposit.last
      patch void_till_deposit_path(wrong_deposit), params: { void_reason: "Wrong amount entered" }
      original_attributes = wrong_deposit.reload.attributes

      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "17900.00", deposited_at: Time.current.to_s }
      }

      expect(TillDeposit.count).to eq(2)
      replacement = TillDeposit.active.sole
      expect(replacement.id).not_to eq(wrong_deposit.id)
      expect(replacement.amount).to eq(17_900)
      expect(wrong_deposit.reload.attributes).to eq(original_attributes)
    end

    it "makes the replacement the active deposit used by every DR-level calculation" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "15750.00", deposited_at: Time.current.to_s }
      }
      wrong_deposit = TillDeposit.last
      patch void_till_deposit_path(wrong_deposit), params: { void_reason: "Wrong amount entered" }

      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "17900.00", deposited_at: Time.current.to_s }
      }

      expect(dr.reload.state).to eq("deposited")
      expect(dr.total_deposited).to eq(17_900)
      expect(dr.pending_deposit_amount).to eq(0)
      expect(dr.active_deposits.sole.amount).to eq(17_900)
    end

    it "preserves Deposit Recorded -> Deposit Voided -> Corrected Deposit Recorded as three separate audit events" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "15750.00", deposited_at: Time.current.to_s }
      }
      original = TillDeposit.last
      patch void_till_deposit_path(original), params: { void_reason: "Wrong amount entered" }

      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "17900.00", deposited_at: Time.current.to_s }
      }
      replacement = TillDeposit.active.sole

      expect(AuditLog.where(auditable: original, action: "create").count).to eq(1)
      expect(AuditLog.where(auditable: original, action: "void").count).to eq(1)
      expect(AuditLog.where(auditable: replacement, action: "create").count).to eq(1)

      get finance_daily_reconciliation_path(dr)
      body = response.body
      expect(body.index(t_till("created"))).not_to be_nil
    end

    it "hides the Correct Deposit action again once a replacement has been recorded" do
      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "15750.00", deposited_at: Time.current.to_s }
      }
      wrong_deposit = TillDeposit.last
      patch void_till_deposit_path(wrong_deposit), params: { void_reason: "Wrong amount entered" }

      post till_deposits_path, params: {
        till_deposit: { daily_reconciliation_id: dr.id, payment_method_id: cash_pm.id,
                       amount: "17900.00", deposited_at: Time.current.to_s }
      }

      get finance_daily_reconciliation_path(dr)
      expect(response.body).not_to include(t_bank("correct_deposit_action"))
    end
  end

  def t_bank(key) = I18n.t("finance.daily_reconciliations.show.sections.bank.#{key}")
  def t_till(key) = I18n.t("till_deposits.#{key}")
end
