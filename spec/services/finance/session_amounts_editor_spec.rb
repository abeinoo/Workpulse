require "rails_helper"

RSpec.describe Finance::SessionAmountsEditor, type: :model do
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
                                payment_method_name: cash_pm.name, collected_amount: 370,
                                refund_amount: 0, kind: "operational")
  end
  let!(:visa_amount) do
    TillHandoverAmount.create!(till_handover: closing_handover, payment_method: visa_pm,
                                payment_method_name: visa_pm.name, collected_amount: 5_956,
                                refund_amount: 0, kind: "operational")
  end

  before { Finance::TillHandoverCreator.sync_session_amounts!(dr, closing_handover) }

  let(:base_amounts) do
    {
      cash_pm.id => { collected_amount: "470", refund_amount: "0" },
      visa_pm.id => { collected_amount: "5956", refund_amount: "0" }
    }
  end

  def edit(amounts: base_amounts, notes: "Branch manager found a counting error")
    described_class.new(dr, actor: actor, amounts: amounts, notes: notes).call
  end

  describe "#call" do
    it "updates the operational amounts on the day-close handover" do
      result = edit
      expect(result.ok?).to be true
      expect(cash_amount.reload.collected_amount).to eq(470)
    end

    it "recomputes Branch Totals (TillSessionAmount) from the corrected handover" do
      edit
      session_amount = dr.session_amounts.find_by(payment_method: cash_pm)
      expect(session_amount.collected_amount).to eq(470)
    end

    it "is reflected live by EmployeeReconciliationSummarizer#summaries, not just the persisted snapshot" do
      edit
      summaries = Finance::EmployeeReconciliationSummarizer.new(dr).summaries
      cash_row  = summaries.first.amounts.find { |a| a.payment_method_id == cash_pm.id }
      expect(cash_row.collected_amount).to eq(470)
    end

    it "recomputes the persisted Employee Reconciliation Summary snapshot too" do
      edit
      summary = dr.employee_reconciliation_summaries.find_by(user: actor)
      expect(summary).to be_present
      cash_summary_amount = summary.amounts.find_by(payment_method: cash_pm)
      expect(cash_summary_amount.collected_amount).to eq(470)
    end

    it "creates exactly one audit log on the DR with the collected/refund diff and notes" do
      edit
      log = AuditLog.where(auditable: dr, action: "edit_session_totals").sole
      expect(log.metadata["notes"]).to eq("Branch manager found a counting error")
      expect(log.changes_json["Cash"]["collected"]).to eq(%w[370.0 470.0])
      expect(log.changes_json).not_to have_key("Visa")
    end

    it "does not write an audit log or touch data when nothing actually changed" do
      unchanged = {
        cash_pm.id => { collected_amount: "370", refund_amount: "0" },
        visa_pm.id => { collected_amount: "5956", refund_amount: "0" }
      }
      expect { edit(amounts: unchanged) }.not_to change(AuditLog, :count)
    end

    context "when notes is blank" do
      it "rejects the edit" do
        result = edit(notes: "")
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.edit_notes_required"))
        expect(cash_amount.reload.collected_amount).to eq(370)
      end
    end

    context "when the DR has been verified" do
      before { dr.update_columns(state: "verified", verified_at: Time.current, verified_by_id: actor.id) }

      it "blocks the edit" do
        result = edit
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.already_verified"))
      end
    end

    context "when the DR has been deposited" do
      before { dr.update_columns(state: "deposited") }

      it "still allows the edit (unlike Day Close Amounts editing)" do
        result = edit
        expect(result.ok?).to be true
        expect(cash_amount.reload.collected_amount).to eq(470)
      end
    end

    context "when the DR is still open (never closed)" do
      before { dr.update_columns(state: "open") }

      it "rejects the edit" do
        result = edit
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.not_closed"))
      end
    end

    context "when there is no day-close handover" do
      before { closing_handover.destroy! }

      it "rejects the edit" do
        result = edit
        expect(result.ok?).to be false
        expect(result.error).to eq(I18n.t("finance.daily_reconciliations.errors.day_close_not_closed"))
      end
    end
  end

  # BUG-003: the amounts are overwritten in place, so the audit entry is the
  # only record of their previous values — no entry, no edit.
  describe "when the audit entry cannot be written (fail-closed)" do
    it "refuses the edit and leaves the handover, session amounts and summary unchanged" do
      fail_audit_writes!(:edit_session_totals)

      result = edit

      expect(result.ok?).to be false
      expect(result.error).to eq(I18n.t("audit_log.errors.write_failed"))
      expect(cash_amount.reload.collected_amount).to eq(370)
      expect(dr.session_amounts.find_by(payment_method: cash_pm).collected_amount).to eq(370)
      expect(AuditLog.where(auditable: dr)).to be_empty
    end
  end
end
