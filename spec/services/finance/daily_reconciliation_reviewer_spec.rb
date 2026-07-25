require "rails_helper"

RSpec.describe Finance::DailyReconciliationReviewer, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }
  let(:cash_pm)  { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  # Deposited by default — Branch Review now happens AFTER the deposit is
  # recorded, not before.
  let(:dr) do
    DailyReconciliation.create!(
      branch: branch, business: business, state: "deposited",
      opened_at: 1.hour.ago, closed_at: Time.current, business_date: Date.current
    )
  end
  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }
  let!(:deposit) do
    dr.till_deposits.create!(payment_method: cash_pm, deposited_by: actor, amount: 100, deposited_at: Time.current)
  end

  def review(dr_id: dr.id)
    described_class.new(dr_id, actor: actor).call
  end

  describe "#call" do
    it "marks the reconciliation as reviewed" do
      result = review
      expect(result.ok?).to be true
      expect(dr.reload.reviewed?).to be true
      expect(dr.reviewed_by).to eq(actor)
      expect(dr.reviewed_at).to be_present
    end

    it "writes an audit log" do
      review
      log = AuditLog.where(auditable: dr, action: "review_completed").sole
      expect(log.actor).to eq(actor)
    end

    it "rejects when already reviewed" do
      review
      result = review
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.already_reviewed"))
    end

    it "rejects when no deposit has been recorded yet (only closed)" do
      dr.till_deposits.destroy_all
      dr.update_columns(state: "closed")
      result = review
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.review_not_deposited"))
    end

    it "rejects when the DR is still open" do
      dr.till_deposits.destroy_all
      dr.update_columns(state: "open")
      result = review
      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.review_not_deposited"))
    end

    context "pending prerequisites" do
      let(:sender)   { create(:user, business: business) }
      let(:receiver) { create(:user, business: business) }

      it "rejects when a till handover is still pending" do
        TillHandover.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver,
                              self_deposit: false, fresha_date: dr.business_date)

        result = review
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.review_pending_handovers"))
      end

      it "rejects when a deposit responsibility transfer is still pending" do
        DepositResponsibilityTransfer.create!(daily_reconciliation: dr, from_user: sender, to_user: receiver)

        result = review
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.review_pending_deposit_transfer"))
      end

      # POS Transactions Verification is a later, independent operational step
      # (after deposits), not a Branch Review prerequisite — regression guard
      # for that decision.
      it "allows review even when imported POS data does not match session totals" do
        TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                  collected_amount: 500, refund_amount: 0)
        pos_import = PosImport.create!(business: business, imported_by: actor, file_name: "x.csv", status: "imported")
        PosTransaction.create!(pos_import: pos_import, business: business, daily_reconciliation: dr,
                               transaction_date: Date.current, cashier_name: "Someone", branch_name: branch.name,
                               payment_method_name: "Cash", amount: 300)

        result = review
        expect(result.ok?).to be true
      end

      it "allows review when the business has never imported POS data" do
        result = review
        expect(result.ok?).to be true
      end
    end
  end
end
