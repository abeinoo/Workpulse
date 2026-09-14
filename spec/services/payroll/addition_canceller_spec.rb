require "rails_helper"

RSpec.describe Payroll::AdditionCanceller do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business, status: :draft) }
  let(:employee) { create(:user, business: business) }
  let(:manager)  { create(:user, :accountant, business: business) }

  # Entry with base 5000 and one approved commission bonus of 300, backed by a
  # line item so recalculate_totals! keeps net_salary in sync.
  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5_000.0, total_bonuses: 300.0, net_salary: 5_300.0)
  end
  let!(:bonus) do
    create(:payroll_line_item, :commission, payroll_entry: entry, amount: 300.0)
  end

  describe "call" do
    it "excludes the addition from totals and lowers net salary" do
      result = described_class.call(line_item: bonus, actor: manager, reason: "Entered in error")

      expect(result.success?).to be true
      bonus.reload
      expect(bonus.addition_cancelled?).to be true
      expect(bonus.addition_cancelled_by).to eq(manager)
      expect(bonus.addition_cancellation_reason).to eq("Entered in error")
      expect(bonus.addition_cancelled_at).to be_present

      entry.reload
      expect(entry.total_bonuses).to eq(0.0)
      expect(entry.net_salary).to eq(5_000.0)
    end

    it "does not require a reason" do
      result = described_class.call(line_item: bonus, actor: manager)
      expect(result.success?).to be true
      expect(bonus.reload.addition_cancellation_reason).to be_nil
    end

    it "does NOT modify the source adjustment record" do
      adjustment = create(:payroll_adjustment, :cash_incentive, payroll_period: period,
                          user: employee, amount: 300.0, review_status: "approved")
      bonus.update!(source_id: adjustment.id, source_type: "PayrollAdjustment")

      described_class.call(line_item: bonus, actor: manager, reason: "x")

      expect(adjustment.reload.review_status).to eq("approved")
      expect(adjustment.amount).to eq(300.0)
    end

    it "does not exclude already_paid bonuses that stay active from already_paid_total" do
      paid_bonus = create(:payroll_line_item, :cash_incentive, payroll_entry: entry,
                          amount: 150.0, already_paid: true)
      entry.recalculate_totals!
      expect(entry.already_paid_total).to eq(150.0)
    end

    it "excludes a cancelled already_paid bonus from already_paid_total" do
      paid_bonus = create(:payroll_line_item, :cash_incentive, payroll_entry: entry,
                          amount: 150.0, already_paid: true)
      entry.recalculate_totals!

      described_class.call(line_item: paid_bonus, actor: manager, reason: "x")

      expect(entry.reload.already_paid_total).to eq(0.0)
    end

    it "rejects cancelling an addition that is already cancelled" do
      described_class.call(line_item: bonus, actor: manager, reason: "x")
      result = described_class.call(line_item: bonus, actor: manager, reason: "y")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.addition_cancellation.errors.already_cancelled"))
    end

    it "rejects a deduction line item" do
      deduction = create(:payroll_line_item, :late_penalty, payroll_entry: entry)
      result = described_class.call(line_item: deduction, actor: manager, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.addition_cancellation.errors.not_cancellable"))
    end

    it "is forbidden without the manage_payroll_addition_cancellations permission" do
      other = create(:user, business: business)
      result = described_class.call(line_item: bonus, actor: other, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.addition_cancellation.errors.permission"))
    end

    it "is blocked on a locked (finalized) period" do
      period.update!(status: :finalized)
      result = described_class.call(line_item: bonus, actor: manager, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.addition_cancellation.errors.locked"))
    end

    it "is blocked on a paid period" do
      period.update!(status: :finalized)
      period.update!(status: :paid)
      result = described_class.call(line_item: bonus, actor: manager, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.addition_cancellation.errors.locked"))
    end
  end

  # ── Overtime cancellation (system-generated, not manager-submitted) ─────────
  # There is no type allowlist for cancellation: any item shown in "الإضافات
  # والمكافآت" — including overtime — must be cancellable per business rule.
  describe "overtime cancellation" do
    # A separate employee/entry — the outer `let!(:bonus)` already creates a
    # PayrollEntry for `employee` on `period`, and PayrollEntry enforces one
    # entry per (user, period).
    let(:ot_employee) { create(:user, business: business) }
    let(:ot_entry) do
      create(:payroll_entry, payroll_period: period, user: ot_employee,
             base_salary: 5_000.0, total_overtime: 200.0, calculated_overtime_pay: 200.0,
             net_salary: 5_200.0)
    end
    let!(:overtime_item) do
      create(:payroll_line_item, :overtime, payroll_entry: ot_entry, amount: 200.0)
    end

    it "is cancellable" do
      expect(overtime_item.addition_cancellable?).to be true
    end

    it "excludes the overtime item from total_overtime and lowers net salary" do
      result = described_class.call(line_item: overtime_item, actor: manager, reason: "Not worked")

      expect(result.success?).to be true
      expect(overtime_item.reload.addition_cancelled?).to be true

      ot_entry.reload
      expect(ot_entry.total_overtime).to eq(0.0)
      expect(ot_entry.calculated_overtime_pay).to eq(0.0)
      expect(ot_entry.net_salary).to eq(5_000.0)
    end

    # ── "المحتسب" (calculated_overtime_pay) and "المعتمد" (payable_overtime_pay) —
    # the two figures shown on the Payroll Entry page must both drop to zero
    # once the only overtime item is cancelled (no override in play, so
    # payable_overtime_pay mirrors calculated_overtime_pay exactly).
    it "recalculates both المحتسب (calculated_overtime_pay) and المعتمد (payable_overtime_pay) to zero" do
      described_class.call(line_item: overtime_item, actor: manager, reason: "Not worked")

      ot_entry.reload
      expect(ot_entry.calculated_overtime_pay).to eq(0.0)
      expect(ot_entry.payable_overtime_pay).to eq(0.0)
    end

    it "excludes only the cancelled day when other overtime line items remain" do
      other_day = create(:payroll_line_item, :overtime, payroll_entry: ot_entry, amount: 75.0)
      ot_entry.recalculate_totals!

      described_class.call(line_item: overtime_item, actor: manager, reason: "Not worked")

      ot_entry.reload
      expect(ot_entry.total_overtime).to eq(75.0)
      expect(ot_entry.calculated_overtime_pay).to eq(75.0)
      expect(ot_entry.payable_overtime_pay).to eq(75.0)
      expect(other_day.reload.addition_cancelled?).to be false
    end

    it "recalculates to zero after cancelling multiple overtime items one after another" do
      other_day = create(:payroll_line_item, :overtime, payroll_entry: ot_entry, amount: 75.0)
      ot_entry.recalculate_totals!

      described_class.call(line_item: overtime_item, actor: manager, reason: "Not worked")
      described_class.call(line_item: other_day, actor: manager, reason: "Not worked either")

      ot_entry.reload
      expect(overtime_item.reload.addition_cancelled?).to be true
      expect(other_day.reload.addition_cancelled?).to be true
      expect(ot_entry.total_overtime).to eq(0.0)
      expect(ot_entry.calculated_overtime_pay).to eq(0.0)
      expect(ot_entry.payable_overtime_pay).to eq(0.0)
      expect(ot_entry.net_salary).to eq(5_000.0)
    end

    context "when an 'amount' overtime override is active" do
      before do
        ot_entry.update!(calculated_overtime_minutes: 120)
        Payroll::OvertimeOverrider.call(entry: ot_entry, mode: "amount", value: 150.0,
                                        reason: "Capped by policy", actor: manager)
      end

      it "clamps المعتمد (payable/approved) down when المحتسب (calculated) drops below the override" do
        # Before cancelling: calculated=200, override caps payable at 150.
        expect(ot_entry.reload.calculated_overtime_pay).to eq(200.0)
        expect(ot_entry.payable_overtime_pay).to eq(150.0)

        described_class.call(line_item: overtime_item, actor: manager, reason: "Not worked")

        ot_entry.reload
        # calculated_ot is now 0 (the only overtime item was cancelled) — the
        # override can never exceed what's actually calculated, so it clamps to 0.
        expect(ot_entry.calculated_overtime_pay).to eq(0.0)
        expect(ot_entry.approved_overtime_pay).to eq(0.0)
        expect(ot_entry.payable_overtime_pay).to eq(0.0)
      end

      it "leaves المعتمد unchanged when المحتسب stays above the override" do
        other_day = create(:payroll_line_item, :overtime, payroll_entry: ot_entry, amount: 100.0)
        ot_entry.recalculate_totals!

        described_class.call(line_item: other_day, actor: manager, reason: "Not worked")

        ot_entry.reload
        # calculated_ot is now 200 (only overtime_item remains) — still above
        # the 150 override, so the override is preserved unchanged.
        expect(ot_entry.calculated_overtime_pay).to eq(200.0)
        expect(ot_entry.approved_overtime_pay).to eq(150.0)
        expect(ot_entry.payable_overtime_pay).to eq(150.0)
      end
    end

    it "keeps the original overtime record in the database, unmodified in amount" do
      described_class.call(line_item: overtime_item, actor: manager, reason: "x")
      expect(PayrollLineItem.find(overtime_item.id).amount).to eq(200.0)
    end

    it "cannot be cancelled twice" do
      described_class.call(line_item: overtime_item, actor: manager, reason: "x")
      result = described_class.call(line_item: overtime_item, actor: manager, reason: "y")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.addition_cancellation.errors.already_cancelled"))
    end

    it "is forbidden without the permission" do
      other = create(:user, business: business)
      result = described_class.call(line_item: overtime_item, actor: other, reason: "x")
      expect(result.success?).to be false
      expect(overtime_item.reload.addition_cancelled?).to be false
    end

    it "is blocked on a locked (finalized) period" do
      period.update!(status: :finalized)
      result = described_class.call(line_item: overtime_item, actor: manager, reason: "x")
      expect(result.success?).to be false
      expect(result.error).to eq(I18n.t("payroll.addition_cancellation.errors.locked"))
    end
  end

  describe "audit logging" do
    it "writes an addition_cancelled audit log with the required fields" do
      expect {
        described_class.call(line_item: bonus, actor: manager, reason: "Entered in error")
      }.to change { PayrollAuditLog.where(action_type: "addition_cancelled").count }.by(1)

      log = PayrollAuditLog.where(action_type: "addition_cancelled").last
      expect(log.payroll_period).to eq(period)
      expect(log.actor).to eq(manager)

      meta = log.metadata_hash
      expect(meta["payroll_period_id"]).to eq(period.id)
      expect(meta["payroll_entry_id"]).to eq(entry.id)
      expect(meta["addition_id"]).to eq(bonus.id)
      expect(meta["employee_id"]).to eq(employee.id)
      expect(meta["old_state"]).to eq("active")
      expect(meta["new_state"]).to eq("cancelled")
      expect(meta["reason"]).to eq("Entered in error")
      expect(meta["actor_id"]).to eq(manager.id)
      expect(meta["timestamp"]).to be_present
    end
  end
end
