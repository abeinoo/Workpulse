require "rails_helper"

RSpec.describe EmployeeObligation, type: :model do
  subject(:obligation) { build(:employee_obligation) }

  # ── Associations ──────────────────────────────────────────────────────────
  describe "associations" do
    it { is_expected.to belong_to(:user) }
    it { is_expected.to belong_to(:business) }
    it { is_expected.to belong_to(:created_by).class_name("User") }
    it { is_expected.to have_many(:obligation_deductions).dependent(:destroy) }
    it { is_expected.to have_many(:obligation_postponements).dependent(:destroy) }
  end

  # ── Validations ───────────────────────────────────────────────────────────
  describe "validations" do
    it { is_expected.to validate_presence_of(:obligation_type) }
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:total_amount) }
    it { is_expected.to validate_presence_of(:remaining_amount) }
    it { is_expected.to validate_presence_of(:installment_amount) }
    it { is_expected.to validate_presence_of(:start_month) }
    it { is_expected.to validate_presence_of(:start_year) }

    it "requires start_month to be 1-12" do
      expect(build(:employee_obligation, start_month: 0)).not_to be_valid
      expect(build(:employee_obligation, start_month: 13)).not_to be_valid
      expect(build(:employee_obligation, start_month: 6)).to be_valid
    end

    it "requires start_year > 2000" do
      expect(build(:employee_obligation, start_year: 1999)).not_to be_valid
      expect(build(:employee_obligation, start_year: 2025)).to be_valid
    end

    it "requires end_month and end_year together" do
      expect(build(:employee_obligation, start_month: 1, start_year: 2025, end_month: 6, end_year: nil)).not_to be_valid
      expect(build(:employee_obligation, start_month: 1, start_year: 2025, end_month: nil, end_year: 2025)).not_to be_valid
      expect(build(:employee_obligation, start_month: 1, start_year: 2025, end_month: 6, end_year: 2025)).to be_valid
    end

    it "rejects end period before start period" do
      expect(
        build(:employee_obligation, start_month: 6, start_year: 2025, end_month: 5, end_year: 2025)
      ).not_to be_valid
    end

    it "allows end period equal to start period" do
      expect(
        build(:employee_obligation, start_month: 6, start_year: 2025, end_month: 6, end_year: 2025)
      ).to be_valid
    end

    it "allows end period after start period" do
      expect(
        build(:employee_obligation, start_month: 6, start_year: 2025, end_month: 1, end_year: 2026)
      ).to be_valid
    end
  end

  # ── Financial integrity validations ───────────────────────────────────────
  describe "financial integrity" do
    it "rejects total_amount of zero" do
      expect(build(:employee_obligation, total_amount: 0, remaining_amount: 0)).not_to be_valid
    end

    it "rejects installment_amount greater than total_amount" do
      expect(build(:employee_obligation, total_amount: 500, installment_amount: 600,
                   remaining_amount: 500, installments_count: 1)).not_to be_valid
    end

    it "rejects remaining_amount greater than total_amount" do
      expect(build(:employee_obligation, total_amount: 1000, remaining_amount: 1500,
                   installments_count: 2)).not_to be_valid
    end

    it "rejects installments_count inconsistent with total and installment" do
      # total=5000, installment=900 → ceil(5000/900) = 6, not 5
      obligation = build(:employee_obligation, total_amount: 5000, installment_amount: 900,
                         remaining_amount: 5000, installments_count: 5)
      expect(obligation).not_to be_valid
      expect(obligation.errors[:installments_count]).to be_present
    end

    it "accepts installments_count consistent with total and installment (exact division)" do
      # total=3000, installment=500 → ceil(3000/500) = 6
      expect(build(:employee_obligation, total_amount: 3000, installment_amount: 500,
                   remaining_amount: 3000, installments_count: 6)).to be_valid
    end

    it "accepts installments_count consistent with non-divisible total (last installment smaller)" do
      # total=5000, installment=900 → ceil(5000/900) = 6
      expect(build(:employee_obligation, total_amount: 5000, installment_amount: 900,
                   remaining_amount: 5000, installments_count: 6)).to be_valid
    end
  end

  # ── Instance Methods ──────────────────────────────────────────────────────
  describe "#installment_for_period" do
    it "returns the installment amount when remaining is larger" do
      obligation = build(:employee_obligation, installment_amount: 500, remaining_amount: 3000)
      expect(obligation.installment_for_period).to eq(500.0)
    end

    it "returns the remaining amount when smaller than installment" do
      obligation = build(:employee_obligation, installment_amount: 500, remaining_amount: 200)
      expect(obligation.installment_for_period).to eq(200.0)
    end
  end

  describe "#repay!" do
    let!(:obligation) { create(:employee_obligation, total_amount: 1000, remaining_amount: 1000) }

    it "decrements remaining_amount" do
      obligation.repay!(200)
      expect(obligation.reload.remaining_amount).to eq(800)
    end

    it "does not reduce remaining below zero" do
      obligation.repay!(1500)
      expect(obligation.reload.remaining_amount).to eq(0)
    end

    it "marks as completed when remaining reaches zero" do
      obligation.repay!(1000)
      expect(obligation.reload.status).to eq("completed")
    end

    it "stays active when remaining is still positive" do
      obligation.repay!(500)
      expect(obligation.reload.status).to eq("active")
    end
  end

  describe "#restore!" do
    let!(:obligation) { create(:employee_obligation, total_amount: 1000, remaining_amount: 500, status: "active") }

    it "increments remaining_amount" do
      obligation.restore!(200)
      expect(obligation.reload.remaining_amount).to eq(700)
    end

    it "does not exceed total_amount" do
      obligation.restore!(2000)
      expect(obligation.reload.remaining_amount).to eq(1000)
    end

    it "reactivates a completed obligation when balance restored" do
      obligation.update!(remaining_amount: 0, status: "completed")
      obligation.restore!(100)
      expect(obligation.reload.status).to eq("active")
    end
  end

  describe "#repaid_amount" do
    it "returns the difference between total and remaining" do
      obligation = build(:employee_obligation, total_amount: 1000, remaining_amount: 600)
      expect(obligation.repaid_amount).to eq(400.0)
    end

    it "returns 0.0 when total_amount is nil (unsaved form)" do
      obligation = EmployeeObligation.new
      expect(obligation.repaid_amount).to eq(0.0)
    end
  end

  describe "#percent_repaid" do
    it "calculates the percentage repaid" do
      obligation = build(:employee_obligation, total_amount: 1000, remaining_amount: 750)
      expect(obligation.percent_repaid).to eq(25.0)
    end

    it "returns 100 when total_amount is zero" do
      obligation = build(:employee_obligation, total_amount: 0, remaining_amount: 0)
      expect(obligation.percent_repaid).to eq(100)
    end

    it "returns 100 when total_amount is nil (unsaved form)" do
      obligation = EmployeeObligation.new
      expect(obligation.percent_repaid).to eq(100)
    end
  end

  describe "#final_installment_amount" do
    it "returns the remainder after full installments" do
      obligation = build(:employee_obligation, total_amount: 5000, installment_amount: 900)
      # 5000 / 900 = 5 full + 500 remainder
      expect(obligation.final_installment_amount).to eq(500.0)
    end

    it "returns 0.0 when evenly divisible" do
      obligation = build(:employee_obligation, total_amount: 3000, installment_amount: 500)
      expect(obligation.final_installment_amount).to eq(0.0)
    end

    it "returns 0.0 when total_amount is nil (unsaved form, no crash)" do
      obligation = EmployeeObligation.new
      expect(obligation.final_installment_amount).to eq(0.0)
    end

    it "returns 0.0 when installment_amount is nil (unsaved form, no crash)" do
      obligation = EmployeeObligation.new(total_amount: 1000)
      expect(obligation.final_installment_amount).to eq(0.0)
    end

    it "returns 0.0 when both amounts are nil (unsaved form, no crash)" do
      obligation = EmployeeObligation.new
      expect { obligation.final_installment_amount }.not_to raise_error
    end
  end

  describe "#even_installments?" do
    it "returns true when total is exactly divisible by installment" do
      obligation = build(:employee_obligation, total_amount: 3000, installment_amount: 500)
      expect(obligation.even_installments?).to be true
    end

    it "returns false when there is a remainder" do
      obligation = build(:employee_obligation, total_amount: 5000, installment_amount: 900)
      expect(obligation.even_installments?).to be false
    end

    it "returns true (no crash) when amounts are nil (unsaved form)" do
      obligation = EmployeeObligation.new
      expect { obligation.even_installments? }.not_to raise_error
      expect(obligation.even_installments?).to be true
    end
  end

  # ── Scopes ────────────────────────────────────────────────────────────────
  describe ".covering_period" do
    let(:business) { create(:business) }
    let(:user)     { create(:user, business: business) }
    let(:period)   { create(:payroll_period, business: business, period_month: 6, period_year: 2025) }

    it "includes an obligation that starts before and has no end" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 1, start_year: 2025)
      expect(EmployeeObligation.covering_period(period)).to include(obligation)
    end

    it "includes an obligation starting exactly on the period" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 6, start_year: 2025)
      expect(EmployeeObligation.covering_period(period)).to include(obligation)
    end

    it "excludes an obligation that starts after the period" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 7, start_year: 2025)
      expect(EmployeeObligation.covering_period(period)).not_to include(obligation)
    end

    it "excludes an obligation that ends before the period" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 1, start_year: 2025,
                          end_month: 5, end_year: 2025)
      expect(EmployeeObligation.covering_period(period)).not_to include(obligation)
    end

    it "includes an obligation that ends on the period month" do
      obligation = create(:employee_obligation, user: user, business: business,
                          start_month: 1, start_year: 2025,
                          end_month: 6, end_year: 2025)
      expect(EmployeeObligation.covering_period(period)).to include(obligation)
    end
  end

  # ── Installment postponement ─────────────────────────────────────────────
  describe "#installment_schedule with postponements" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             total_amount: 12_000, remaining_amount: 12_000, installment_amount: 2_000,
             installments_count: 6, start_month: 8, start_year: 2026, status: "active")
    end

    it "shows the un-postponed schedule by default" do
      schedule = obligation.installment_schedule
      expect(schedule.size).to eq(6)
      expect(schedule.map { |e| e[:amount] }).to all(eq(2_000.0))
      expect(schedule).to all(include(status: :scheduled))
    end

    context "next_month postponement" do
      before do
        create(:obligation_postponement, employee_obligation: obligation,
               postponement_type: "next_month",
               original_year: 2026, original_month: 8, original_amount: 2_000,
               target_year: 2026, target_month: 9, amount: 2_000)
      end

      it "zeroes the original installment and marks it postponed" do
        entry = obligation.installment_schedule.find { |e| e[:year] == 2026 && e[:month] == 8 }
        expect(entry[:amount]).to eq(0.0)
        expect(entry[:status]).to eq(:postponed)
      end

      it "adds the postponed amount onto the next installment" do
        entry = obligation.installment_schedule.find { |e| e[:year] == 2026 && e[:month] == 9 }
        expect(entry[:amount]).to eq(4_000.0)
        expect(entry[:status]).to eq(:scheduled)
      end

      it "leaves the schedule length and total unchanged" do
        schedule = obligation.installment_schedule
        expect(schedule.size).to eq(6)
        expect(schedule.sum { |e| e[:amount] }).to eq(12_000.0)
      end

      it "does not touch other installments" do
        entry = obligation.installment_schedule.find { |e| e[:year] == 2026 && e[:month] == 10 }
        expect(entry[:amount]).to eq(2_000.0)
      end
    end

    context "extend_loan postponement" do
      before do
        create(:obligation_postponement, :extend_loan, employee_obligation: obligation,
               original_year: 2026, original_month: 8, original_amount: 2_000,
               target_year: 2027, target_month: 2, amount: 2_000)
      end

      it "zeroes the original installment and marks it postponed" do
        entry = obligation.installment_schedule.find { |e| e[:year] == 2026 && e[:month] == 8 }
        expect(entry[:amount]).to eq(0.0)
        expect(entry[:status]).to eq(:postponed)
      end

      it "leaves the middle installments untouched" do
        entry = obligation.installment_schedule.find { |e| e[:year] == 2026 && e[:month] == 9 }
        expect(entry[:amount]).to eq(2_000.0)
      end

      it "appends a new installment after the schedule, marked postponed" do
        schedule = obligation.installment_schedule
        expect(schedule.size).to eq(7)
        appended = schedule.last
        expect(appended[:year]).to eq(2027)
        expect(appended[:month]).to eq(2)
        expect(appended[:amount]).to eq(2_000.0)
        expect(appended[:status]).to eq(:postponed)
      end

      it "keeps the total scheduled amount equal to the obligation total" do
        expect(obligation.installment_schedule.sum { |e| e[:amount] }).to eq(12_000.0)
      end
    end
  end

  describe "#postponable?" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             total_amount: 12_000, remaining_amount: 12_000, installment_amount: 2_000,
             installments_count: 6, start_month: 8, start_year: 2026, status: "active")
    end

    it "is true for a future, unpaid, unpostponed installment" do
      expect(obligation.postponable?(2026, 8)).to be true
    end

    it "is false outside the schedule window" do
      expect(obligation.postponable?(2030, 1)).to be false
    end

    it "is false once the obligation is cancelled" do
      obligation.update!(status: "cancelled")
      expect(obligation.postponable?(2026, 8)).to be false
    end

    it "is false once the obligation is completed" do
      obligation.update!(status: "completed", remaining_amount: 0)
      expect(obligation.postponable?(2026, 8)).to be false
    end

    it "is false for an installment already postponed" do
      create(:obligation_postponement, employee_obligation: obligation,
             original_year: 2026, original_month: 8)
      expect(obligation.postponable?(2026, 8)).to be false
    end

    it "is false once that period's payroll is finalized" do
      business = obligation.business
      period   = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "finalized")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      expect(obligation.postponable?(2026, 8)).to be false
    end

    it "is true even when a draft deduction snapshot already exists for that period" do
      # Draft/under_review/branch_review_completed periods are still fully
      # mutable in this codebase (see Payroll::ObligationEditor) — a preview
      # snapshot is not the same as a processed installment.
      business = obligation.business
      period   = create(:payroll_period, business: business, period_year: 2026, period_month: 8, status: "draft")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      expect(obligation.postponable?(2026, 8)).to be true
    end

    it "is true while paused" do
      obligation.update!(status: "paused")
      expect(obligation.postponable?(2026, 8)).to be true
    end

    it "is false for a period whose payroll is finalized, even with no deduction on this obligation" do
      create(:payroll_period, business: obligation.business, period_year: 2026, period_month: 8, status: "finalized")
      expect(obligation.postponable?(2026, 8)).to be false
    end

    it "is still true for a later untouched installment even though an earlier period is finalized/paid" do
      # Regression: payroll_locked? is obligation-wide and must NOT be used
      # here — a paid June/July shouldn't freeze postponement of November.
      period = create(:payroll_period, business: obligation.business, period_year: 2026, period_month: 8, status: "paid")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      expect(obligation.payroll_locked?).to be true
      expect(obligation.postponable?(2026, 10)).to be true
    end
  end

  describe "#period_finalized?" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             total_amount: 12_000, remaining_amount: 12_000, installment_amount: 2_000,
             installments_count: 6, start_month: 8, start_year: 2026, status: "active")
    end

    it "is false for a period with no payroll period at all" do
      expect(obligation.period_finalized?(2026, 8)).to be false
    end

    it "is false when a deduction exists but its period is still draft" do
      period = create(:payroll_period, business: obligation.business, period_year: 2026, period_month: 8, status: "draft")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      expect(obligation.period_finalized?(2026, 8)).to be false
    end

    it "is true when the business's payroll period for that month is finalized, even without a deduction" do
      create(:payroll_period, business: obligation.business, period_year: 2026, period_month: 9, status: "finalized")
      expect(obligation.period_finalized?(2026, 9)).to be true
    end

    it "is true when the period is paid" do
      period = create(:payroll_period, business: obligation.business, period_year: 2026, period_month: 8, status: "paid")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 12_000, remaining_after: 10_000)
      expect(obligation.period_finalized?(2026, 8)).to be true
    end
  end

  describe "#next_month_postponable?" do
    it "is false when the next installment falls outside a closed end window" do
      obligation = create(:employee_obligation, :with_end_date,
                          total_amount: 2_000, remaining_amount: 2_000, installment_amount: 2_000,
                          installments_count: 1, start_month: 1, start_year: 2026,
                          end_month: 1, end_year: 2026, status: "active")
      expect(obligation.next_month_postponable?(2026, 1)).to be false
      expect(obligation.extend_loan_postponable?(2026, 1)).to be true
    end

    it "is false when the next installment's period is already finalized" do
      obligation = create(:employee_obligation, :open_ended,
                          total_amount: 6_000, remaining_amount: 6_000, installment_amount: 2_000,
                          installments_count: 3, start_month: 8, start_year: 2026, status: "active")
      period = create(:payroll_period, business: obligation.business, period_year: 2026, period_month: 9, status: "finalized")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 6_000, remaining_after: 4_000)
      expect(obligation.next_month_postponable?(2026, 8)).to be false
    end

    it "is true when the next installment only has a draft (non-finalized) deduction" do
      obligation = create(:employee_obligation, :open_ended,
                          total_amount: 6_000, remaining_amount: 6_000, installment_amount: 2_000,
                          installments_count: 3, start_month: 8, start_year: 2026, status: "active")
      period = create(:payroll_period, business: obligation.business, period_year: 2026, period_month: 9, status: "draft")
      create(:obligation_deduction, employee_obligation: obligation, payroll_period: period,
             deducted_amount: 2_000, remaining_before: 6_000, remaining_after: 4_000)
      expect(obligation.next_month_postponable?(2026, 8)).to be true
    end
  end

  describe "#installment_for_period" do
    let(:obligation) do
      create(:employee_obligation, :open_ended,
             total_amount: 12_000, remaining_amount: 12_000, installment_amount: 2_000,
             installments_count: 6, start_month: 8, start_year: 2026, status: "active")
    end
    let(:business) { obligation.business }

    it "returns 0 for a period whose installment was postponed away" do
      create(:obligation_postponement, employee_obligation: obligation,
             original_year: 2026, original_month: 8, target_year: 2026, target_month: 9)
      august = create(:payroll_period, business: business, period_year: 2026, period_month: 8)
      expect(obligation.installment_for_period(august)).to eq(0.0)
    end

    it "returns the increased amount for a period that absorbed a postponement" do
      create(:obligation_postponement, employee_obligation: obligation,
             original_year: 2026, original_month: 8, target_year: 2026, target_month: 9)
      september = create(:payroll_period, business: business, period_year: 2026, period_month: 9)
      expect(obligation.installment_for_period(september)).to eq(4_000.0)
    end
  end
end
