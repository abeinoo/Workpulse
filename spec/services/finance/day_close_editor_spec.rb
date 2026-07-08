require "rails_helper"

RSpec.describe Finance::DayCloseEditor, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:actor)    { create(:user, business: business) }

  let(:cash_pm) do
    PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true)
  end
  let(:visa_pm) do
    PaymentMethod.create!(business: business, name: "Visa", settlement_type: "card", active: true)
  end

  let(:dr) do
    DailyReconciliation.create!(
      branch:        branch,
      business:      business,
      state:         "closed",
      opened_at:     1.hour.ago,
      closed_at:     Time.current,
      business_date: Date.current
    )
  end

  let!(:till_session) { TillSession.create!(daily_reconciliation: dr, depositor_id: actor.id) }

  let!(:closing_handover) do
    TillHandover.create!(
      daily_reconciliation:      dr,
      from_user:                 actor,
      self_deposit:              true,
      opening_float_declaration: false,
      fresha_date:               dr.business_date
    )
  end

  let!(:cash_amount) do
    TillHandoverAmount.create!(till_handover: closing_handover, payment_method: cash_pm,
                                payment_method_name: cash_pm.name, collected_amount: 7_225,
                                refund_amount: 0, kind: "operational")
  end
  let!(:visa_amount) do
    TillHandoverAmount.create!(till_handover: closing_handover, payment_method: visa_pm,
                                payment_method_name: visa_pm.name, collected_amount: 4_801,
                                refund_amount: 0, kind: "operational")
  end

  let(:base_amounts) do
    {
      cash_pm.id => { collected_amount: "7250", refund_amount: "0" },
      visa_pm.id => { collected_amount: "4801", refund_amount: "0" }
    }
  end

  def edit(amounts: base_amounts, reason: "Cashier mistyped the cash amount")
    described_class.new(dr, actor: actor, amounts: amounts, reason: reason).call
  end

  describe "#call" do
    it "updates the operational amounts on the day-close handover" do
      result = edit
      expect(result.ok?).to be true
      expect(cash_amount.reload.collected_amount).to eq(7_250)
      expect(visa_amount.reload.collected_amount).to eq(4_801)
    end

    it "recomputes Branch Totals (TillSessionAmount) from the corrected handover" do
      edit
      session_amount = dr.session_amounts.find_by(payment_method: cash_pm)
      expect(session_amount.collected_amount).to eq(7_250)
    end

    it "recomputes the Employee Reconciliation Summary snapshot" do
      edit
      summary = dr.employee_reconciliation_summaries.find_by(user: actor)
      expect(summary).to be_present
      cash_summary_amount = summary.amounts.find_by(payment_method: cash_pm)
      expect(cash_summary_amount.collected_amount).to eq(7_250)
    end

    it "creates exactly one audit log with the collected/refund diff and reason" do
      edit
      log = AuditLog.where(auditable: closing_handover, action: "edit_day_close_amounts").sole
      expect(log.metadata["reason"]).to eq("Cashier mistyped the cash amount")
      expect(log.changes_json["Cash"]["collected"]).to eq(%w[7225.0 7250.0])
      expect(log.changes_json).not_to have_key("Visa")
    end

    it "does not write an audit log or touch data when nothing actually changed" do
      unchanged = {
        cash_pm.id => { collected_amount: "7225", refund_amount: "0" },
        visa_pm.id => { collected_amount: "4801", refund_amount: "0" }
      }
      expect { edit(amounts: unchanged) }.not_to change(AuditLog, :count)
    end

    context "when the reason is blank" do
      it "rejects the edit" do
        result = edit(reason: "")
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.day_close_edit_reason_required"))
        expect(cash_amount.reload.collected_amount).to eq(7_225)
      end
    end

    context "when the DR has been deposited" do
      before { dr.update_columns(state: "deposited") }

      it "blocks the edit with the deposit-specific message" do
        result = edit
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.cannot_edit_after_deposit"))
        expect(cash_amount.reload.collected_amount).to eq(7_225)
      end
    end

    context "when the DR has been verified" do
      before { dr.update_columns(state: "verified", verified_at: Time.current, verified_by_id: actor.id) }

      it "blocks the edit with the verification-specific message" do
        result = edit
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.cannot_edit_after_verification"))
        expect(cash_amount.reload.collected_amount).to eq(7_225)
      end
    end

    context "when the DR is still open (never closed)" do
      before { dr.update_columns(state: "open") }

      it "rejects the edit" do
        result = edit
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.day_close_not_closed"))
      end
    end

    context "Branch Review invalidation" do
      it "clears an existing review and logs it when amounts actually change" do
        dr.update_columns(reviewed_at: 1.minute.ago, reviewed_by_id: actor.id)

        edit

        expect(dr.reload.reviewed?).to be false
        expect(AuditLog.where(auditable: dr, action: "review_auto_cancelled")).to be_present
      end

      it "does not touch review when nothing changed" do
        dr.update_columns(reviewed_at: 1.minute.ago, reviewed_by_id: actor.id)
        unchanged = {
          cash_pm.id => { collected_amount: "7225", refund_amount: "0" },
          visa_pm.id => { collected_amount: "4801", refund_amount: "0" }
        }

        edit(amounts: unchanged)

        expect(dr.reload.reviewed?).to be true
        expect(AuditLog.where(auditable: dr, action: "review_auto_cancelled")).to be_empty
      end

      it "is a no-op when the DR was never reviewed" do
        edit
        expect(AuditLog.where(auditable: dr, action: "review_auto_cancelled")).to be_empty
      end
    end
  end
end
