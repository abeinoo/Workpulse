require "rails_helper"

RSpec.describe Finance::TillHandoverAdjuster, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:sender)   { create(:user, business: business) }
  let(:receiver) { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "open",
      opened_at: 1.hour.ago, business_date: Date.current
    )
  end

  let!(:handover) do
    TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                          self_deposit: false, accepted_at: 1.hour.ago, fresha_date: dr.business_date)
  end

  before do
    TillHandoverAmount.create!(till_handover: handover, payment_method: cash_pm, payment_method_name: "Cash",
                                collected_amount: 370, refund_amount: 0, kind: "operational")
  end

  def adjust(reason_code: "wrong_amounts", notes: "Recount found a discrepancy at handover time")
    described_class.new(
      handover: handover, actor: sender, reason_code: reason_code, notes: notes,
      after_data: [ { payment_method_id: cash_pm.id, collected_amount: "470", refund_amount: "0" } ]
    ).call
  end

  describe "#call" do
    it "records a FinancialAdjustment without mutating the original amount" do
      result = adjust
      expect(result.ok?).to be true
      expect(handover.amounts.reload.first.collected_amount).to eq(370)
      expect(result.record).to be_a(FinancialAdjustment)
    end

    it "clears an existing review and logs it" do
      dr.update_columns(reviewed_at: 1.minute.ago, reviewed_by_id: sender.id)

      adjust

      expect(dr.reload.reviewed?).to be false
      expect(AuditLog.where(auditable: dr, action: "review_auto_cancelled")).to be_present
    end

    it "is a no-op when the DR was never reviewed" do
      adjust
      expect(AuditLog.where(auditable: dr, action: "review_auto_cancelled")).to be_empty
    end
  end
end
