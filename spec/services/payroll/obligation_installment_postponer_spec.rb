require "rails_helper"

RSpec.describe Payroll::ObligationInstallmentPostponer do
  let(:business) { create(:business) }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, :accountant, business: business) }

  let!(:obligation) do
    create(:employee_obligation, :open_ended,
           user: employee, business: business, created_by: actor,
           total_amount: 12_000, remaining_amount: 12_000, installment_amount: 2_000,
           installments_count: 6, start_month: 8, start_year: 2026, status: "active")
  end

  def run(year:, month:, type:, reason: nil)
    described_class.call(
      obligation_id:      obligation.id,
      business:           business,
      actor:              actor,
      year:                year,
      month:               month,
      postponement_type:  type,
      reason:              reason
    )
  end

  describe "next_month" do
    it "succeeds for a future installment" do
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be true
      expect(result.postponement.postponement_type).to eq("next_month")
    end

    it "zeroes the original installment and moves the amount to September" do
      run(year: 2026, month: 8, type: "next_month")
      schedule = obligation.reload.installment_schedule
      expect(schedule.find { |e| e[:month] == 8 && e[:year] == 2026 }[:amount]).to eq(0.0)
      expect(schedule.find { |e| e[:month] == 9 && e[:year] == 2026 }[:amount]).to eq(4_000.0)
    end

    it "does not change total_amount or remaining_amount" do
      expect {
        run(year: 2026, month: 8, type: "next_month")
      }.not_to change { obligation.reload.attributes.slice("total_amount", "remaining_amount", "installments_count") }
    end

    it "logs an audit entry" do
      expect {
        run(year: 2026, month: 8, type: "next_month")
      }.to change(AuditLog, :count).by(1)
      log = AuditLog.last
      expect(log.action).to eq("obligation_installment_postponed")
      expect(log.actor).to eq(actor)
    end

    it "supports postponing the first installment" do
      expect(run(year: 2026, month: 8, type: "next_month").ok?).to be true
    end

    it "supports postponing a middle installment" do
      expect(run(year: 2026, month: 10, type: "next_month").ok?).to be true
    end

    it "supports postponing the last installment (open-ended obligation)" do
      expect(run(year: 2027, month: 1, type: "next_month").ok?).to be true
      schedule = obligation.reload.installment_schedule
      expect(schedule.find { |e| e[:month] == 2 && e[:year] == 2027 }[:amount]).to eq(2_000.0)
    end

    it "chains two consecutive postponements correctly" do
      run(year: 2026, month: 8, type: "next_month")
      result = run(year: 2026, month: 9, type: "next_month")
      expect(result.ok?).to be true
      schedule = obligation.reload.installment_schedule
      expect(schedule.find { |e| e[:month] == 9 && e[:year] == 2026 }[:amount]).to eq(0.0)
      expect(schedule.find { |e| e[:month] == 10 && e[:year] == 2026 }[:amount]).to eq(6_000.0)
    end

    it "rejects postponing the same installment twice" do
      run(year: 2026, month: 8, type: "next_month")
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
    end

    it "rejects postponing an already-deducted (paid) installment" do
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "paid")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      obligation.reload
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
    end

    it "still succeeds postponing an installment that has a draft (not-yet-finalized) deduction — the defining case" do
      # This is the exact scenario the feature must handle: an installment
      # can already have a draft payroll calculation against it and still be
      # postponable, as long as that payroll hasn't been finalized/paid.
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "draft")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      obligation.reload

      result = run(year: 2026, month: 8, type: "next_month")

      expect(result.ok?).to be true
      schedule = obligation.reload.installment_schedule
      expect(schedule.find { |e| e[:month] == 8 && e[:year] == 2026 }[:amount]).to eq(0.0)
      expect(schedule.find { |e| e[:month] == 9 && e[:year] == 2026 }[:amount]).to eq(4_000.0)
      # The stale draft snapshot for August must be gone, and remaining_amount
      # restored — the balance was never really reduced, only relocated.
      expect(ObligationDeduction.where(employee_obligation: obligation, payroll_period: period)).to be_empty
      expect(obligation.reload.remaining_amount).to eq(12_000.0)
    end

    it "rejects postponing an already-postponed installment" do
      create(:obligation_postponement, employee_obligation: obligation,
             original_year: 2026, original_month: 8, target_year: 2026, target_month: 9)
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
    end

    it "still succeeds when the next installment already has a draft (non-finalized) deduction" do
      # A draft snapshot is a preview, not a processed installment — it must
      # not block postponement, matching Payroll::ObligationEditor's own
      # treatment of draft periods as fully mutable.
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 9, status: "draft")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      obligation.reload
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be true
    end

    it "refuses when the next installment's period is already finalized" do
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 9, status: "finalized")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      obligation.reload
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
      expect(result.error).to be_present
    end

    it "refuses when there is no next installment within a closed schedule window" do
      closed = create(:employee_obligation, user: employee, business: business, created_by: actor,
                      total_amount: 2_000, remaining_amount: 2_000, installment_amount: 2_000,
                      installments_count: 1, start_month: 1, start_year: 2026,
                      end_month: 1, end_year: 2026, status: "active")
      result = described_class.call(
        obligation_id: closed.id, business: business, actor: actor,
        year: 2026, month: 1, postponement_type: "next_month"
      )
      expect(result.ok?).to be false
    end

    it "refuses postponing the specific installment whose period is finalized" do
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "finalized")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
    end

    it "still allows postponing a later, untouched installment even though an earlier period is finalized/paid" do
      # A long-running obligation with an already-paid month must not be
      # frozen from postponing a still-untouched later installment — see
      # EmployeeObligation#period_closed? vs #payroll_locked?.
      period = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "finalized")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      result = run(year: 2026, month: 10, type: "next_month")
      expect(result.ok?).to be true
    end

    it "refuses next_month when the target period is finalized/paid, even with no deduction on this obligation yet" do
      create(:payroll_period, business: business, period_year: 2026, period_month: 9, status: "paid")
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
    end

    it "refuses a completed obligation" do
      obligation.update!(status: "completed", remaining_amount: 0)
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
    end

    it "refuses a cancelled obligation" do
      obligation.update!(status: "cancelled")
      result = run(year: 2026, month: 8, type: "next_month")
      expect(result.ok?).to be false
    end
  end

  describe "extend_loan" do
    it "appends a new installment at the end of the schedule" do
      result = run(year: 2026, month: 8, type: "extend_loan")
      expect(result.ok?).to be true
      schedule = obligation.reload.installment_schedule
      expect(schedule.size).to eq(7)
      expect(schedule.last).to include(month: 2, year: 2027, amount: 2_000.0, status: :postponed)
    end

    it "does not change total_amount, remaining_amount or installments_count" do
      expect {
        run(year: 2026, month: 8, type: "extend_loan")
      }.not_to change { obligation.reload.attributes.slice("total_amount", "remaining_amount", "installments_count") }
    end

    it "leaves the middle installments untouched" do
      run(year: 2026, month: 8, type: "extend_loan")
      entry = obligation.reload.installment_schedule.find { |e| e[:month] == 9 && e[:year] == 2026 }
      expect(entry[:amount]).to eq(2_000.0)
    end

    it "works when postponing the last installment" do
      result = run(year: 2027, month: 1, type: "extend_loan")
      expect(result.ok?).to be true
      schedule = obligation.reload.installment_schedule
      expect(schedule.last).to include(month: 2, year: 2027, status: :postponed)
    end

    it "supports multiple extend_loan postponements, appending sequentially" do
      run(year: 2026, month: 8, type: "extend_loan")
      result = run(year: 2026, month: 9, type: "extend_loan")
      expect(result.ok?).to be true
      schedule = obligation.reload.installment_schedule
      expect(schedule.size).to eq(8)
      expect(schedule.last).to include(month: 3, year: 2027, status: :postponed)
    end

    it "logs an audit entry" do
      expect {
        run(year: 2026, month: 8, type: "extend_loan")
      }.to change(AuditLog, :count).by(1)
    end

    it "is not blocked by a closed end window" do
      closed = create(:employee_obligation, user: employee, business: business, created_by: actor,
                      total_amount: 2_000, remaining_amount: 2_000, installment_amount: 2_000,
                      installments_count: 1, start_month: 1, start_year: 2026,
                      end_month: 1, end_year: 2026, status: "active")
      result = described_class.call(
        obligation_id: closed.id, business: business, actor: actor,
        year: 2026, month: 1, postponement_type: "extend_loan"
      )
      expect(result.ok?).to be true
    end
  end

  describe "single-installment obligation" do
    let!(:single) do
      create(:employee_obligation, :open_ended, user: employee, business: business, created_by: actor,
             total_amount: 2_000, remaining_amount: 2_000, installment_amount: 2_000,
             installments_count: 1, start_month: 8, start_year: 2026, status: "active")
    end

    it "extend_loan appends a second installment" do
      result = described_class.call(
        obligation_id: single.id, business: business, actor: actor,
        year: 2026, month: 8, postponement_type: "extend_loan"
      )
      expect(result.ok?).to be true
      schedule = single.reload.installment_schedule
      expect(schedule.size).to eq(2)
      expect(schedule.sum { |e| e[:amount] }).to eq(2_000.0)
    end
  end

  describe "invalid postponement_type" do
    it "is rejected" do
      result = run(year: 2026, month: 8, type: "something_else")
      expect(result.ok?).to be false
    end
  end
end
