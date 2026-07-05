require "rails_helper"

RSpec.describe Payroll::ObligationEditor do
  let(:business) { create(:business, working_days_per_month: 22, timezone: "UTC") }
  let(:employee) { create(:user, business: business) }
  let(:actor)    { create(:user, :accountant, business: business) }

  let!(:salary_profile) do
    create(:salary_profile, :monthly, user: employee, base_amount: 8_800.0,
           effective_from: 1.year.ago.to_date)
  end

  let(:june) { create(:payroll_period, business: business, period_year: 2026, period_month: 6, working_days: 22) }
  let(:july) { create(:payroll_period, business: business, period_year: 2026, period_month: 7, working_days: 23) }

  def run(obligation, attrs)
    described_class.call(
      obligation_id: obligation.id,
      business:      business,
      actor:         actor,
      attrs:         ActionController::Parameters.new(attrs).permit!
    )
  end

  # ── Bug scenario: moving start_month forward past an already-generated period ──

  describe "moving start_month forward" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             user: employee, business: business, created_by: actor,
             start_month: 6, start_year: 2026,
             total_amount: 1_500.0, remaining_amount: 1_500.0, installment_amount: 500.0)
    end

    before { Payroll::EntryCalculator.call(period: june, user: employee, business: business) }

    it "removes the now-invalid June deduction" do
      expect(ObligationDeduction.where(payroll_period: june)).to be_present
      run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(ObligationDeduction.where(payroll_period: june)).to be_empty
    end

    it "removes the obligation_deduction line item from the June entry" do
      run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      entry = june.payroll_entries.find_by(user: employee)
      expect(entry.payroll_line_items.where(item_type: "obligation_deduction")).to be_empty
    end

    it "restores the remaining balance" do
      obligation.reload
      expect(obligation.remaining_amount).to eq(1_000.0)
      run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(obligation.reload.remaining_amount).to eq(1_500.0)
    end

    it "updates the obligation's start_month" do
      run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(obligation.reload.start_month).to eq(7)
    end

    it "logs an audit entry for the edit" do
      expect {
        run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      }.to change(AuditLog, :count).by(1)
    end
  end

  # ── Moving start_month backward into an already-generated, previously-uncovered period ──

  describe "moving start_month backward" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             user: employee, business: business, created_by: actor,
             start_month: 7, start_year: 2026,
             total_amount: 1_500.0, remaining_amount: 1_500.0, installment_amount: 500.0)
    end

    before do
      Payroll::EntryCalculator.call(period: june, user: employee, business: business)
    end

    it "adds a deduction to the now-covered June period" do
      expect(ObligationDeduction.where(payroll_period: june)).to be_empty
      run(obligation, start_month: 6, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(ObligationDeduction.where(payroll_period: june)).to be_present
    end
  end

  # ── Restriction: locked once payroll has left draft/under_review ──

  describe "when a deduction's period is no longer reviewable" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             user: employee, business: business, created_by: actor,
             start_month: 6, start_year: 2026,
             total_amount: 1_500.0, remaining_amount: 1_500.0, installment_amount: 500.0)
    end

    before do
      Payroll::EntryCalculator.call(period: june, user: employee, business: business)
      june.update_column(:status, "finalized")
    end

    it "refuses to edit the obligation" do
      result = run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(result.ok?).to be false
    end

    it "leaves the obligation's schedule untouched" do
      run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(obligation.reload.start_month).to eq(6)
    end

    it "does not remove the finalized June deduction" do
      run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(ObligationDeduction.where(payroll_period: june)).to be_present
    end
  end

  describe "when a deduction's period is still under review" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             user: employee, business: business, created_by: actor,
             start_month: 6, start_year: 2026,
             total_amount: 1_500.0, remaining_amount: 1_500.0, installment_amount: 500.0)
    end

    before do
      Payroll::EntryCalculator.call(period: june, user: employee, business: business)
      june.update_column(:status, "under_review")
    end

    it "still allows the edit and recalculates the period" do
      result = run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(result.ok?).to be true
      expect(ObligationDeduction.where(payroll_period: june)).to be_empty
    end
  end

  describe "when a deduction's period has completed branch review" do
    let!(:obligation) do
      create(:employee_obligation, :open_ended,
             user: employee, business: business, created_by: actor,
             start_month: 6, start_year: 2026,
             total_amount: 1_500.0, remaining_amount: 1_500.0, installment_amount: 500.0)
    end

    before do
      Payroll::EntryCalculator.call(period: june, user: employee, business: business)
      june.update_column(:status, "branch_review_completed")
    end

    it "still allows the edit and recalculates the period" do
      result = run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(result.ok?).to be true
      expect(ObligationDeduction.where(payroll_period: june)).to be_empty
    end

    it "restores the remaining balance" do
      run(obligation, start_month: 7, start_year: 2026, total_amount: 1_500.0, installment_amount: 500.0)
      expect(obligation.reload.remaining_amount).to eq(1_500.0)
    end
  end
end
