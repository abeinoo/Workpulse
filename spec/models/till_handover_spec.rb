require "rails_helper"

RSpec.describe TillHandover, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }
  let(:visa_pm) { PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
  end

  let!(:handover) do
    TillHandover.create!(daily_reconciliation: dr, from_user: actor, to_user: create(:user, business: business),
                          self_deposit: false, accepted_at: 1.hour.ago, fresha_date: dr.business_date)
  end

  let!(:cash_amount) do
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 370, refund_amount: 0, kind: "operational")
  end
  let!(:visa_amount) do
    TillHandoverAmount.create!(till_handover: handover, payment_method: visa_pm, payment_method_name: "Visa",
                                collected_amount: 5_956, refund_amount: 0, kind: "operational")
  end

  def add_adjustment(after_data:, created_at: Time.current)
    FinancialAdjustment.create!(
      adjustable: handover, business: business, actor: actor, reason_code: "wrong_amounts",
      notes: "Recount found a discrepancy at handover time",
      before_data: [ { payment_method_id: cash_pm.id, collected_amount: "370", refund_amount: "0" } ],
      after_data: after_data, created_at: created_at
    )
  end

  describe "#effective_operational_amounts" do
    it "returns the raw amounts when there is no adjustment" do
      rows = handover.effective_operational_amounts
      cash = rows.find { |r| r[:payment_method_id] == cash_pm.id }
      expect(cash[:collected_amount]).to eq(370)
    end

    it "overrides only the payment method(s) named in the adjustment" do
      add_adjustment(after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ])

      rows = handover.effective_operational_amounts
      cash = rows.find { |r| r[:payment_method_id] == cash_pm.id }
      visa = rows.find { |r| r[:payment_method_id] == visa_pm.id }

      expect(cash[:collected_amount]).to eq(470)
      expect(visa[:collected_amount]).to eq(5_956), "payment methods not named in the adjustment fall back to the original"
    end

    it "does not mutate the original TillHandoverAmount rows" do
      add_adjustment(after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ])

      handover.effective_operational_amounts

      expect(cash_amount.reload.collected_amount).to eq(370)
    end

    it "lets the most recent adjustment win per payment method, across separate adjustments" do
      add_adjustment(after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ],
                     created_at: 2.hours.ago)
      add_adjustment(after_data: [ { payment_method_id: visa_pm.id, collected_amount: "6000", refund_amount: "0" } ],
                     created_at: 1.hour.ago)

      rows = handover.effective_operational_amounts
      cash = rows.find { |r| r[:payment_method_id] == cash_pm.id }
      visa = rows.find { |r| r[:payment_method_id] == visa_pm.id }

      expect(cash[:collected_amount]).to eq(470), "earlier adjustment's PM must still apply when a later one doesn't mention it"
      expect(visa[:collected_amount]).to eq(6_000)
    end

    it "a later adjustment on the same payment method supersedes an earlier one" do
      add_adjustment(after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ],
                     created_at: 2.hours.ago)
      add_adjustment(after_data: [ { payment_method_id: cash_pm.id, collected_amount: "490", refund_amount: "0" } ],
                     created_at: 1.hour.ago)

      rows = handover.effective_operational_amounts
      cash = rows.find { |r| r[:payment_method_id] == cash_pm.id }
      expect(cash[:collected_amount]).to eq(490)
    end
  end
end
