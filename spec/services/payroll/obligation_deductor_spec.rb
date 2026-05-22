require "rails_helper"

RSpec.describe Payroll::ObligationDeductor do
  let(:business) { create(:business) }
  let(:user)     { create(:user, business: business) }
  let(:period)   { create(:payroll_period, business: business, period_month: 6, period_year: 2025) }

  def run
    described_class.call(user: user, period: period)
  end

  context "when there are no obligations" do
    it "returns a result with zero total and no items" do
      result = run
      expect(result.total_amount).to eq(0)
      expect(result.items).to be_empty
    end
  end

  context "when there is one active auto-deductible obligation covering the period" do
    let!(:obligation) do
      create(:employee_obligation,
             user: user, business: business,
             total_amount: 3000, remaining_amount: 3000,
             installment_amount: 500,
             start_month: 1, start_year: 2025,
             status: "active", auto_deduct: true)
    end

    it "returns one item with the correct deducted amount" do
      result = run
      expect(result.items.size).to eq(1)
      expect(result.total_amount).to eq(500)
    end

    it "builds a snapshot with correct remaining_before and remaining_after" do
      result = run
      snapshot = result.items.first.snapshot
      expect(snapshot.remaining_before).to eq(3000)
      expect(snapshot.remaining_after).to  eq(2500)
      expect(snapshot.deducted_amount).to  eq(500)
    end

    it "returns a line item with item_type obligation_deduction and negative amount" do
      result = run
      attrs  = result.items.first.line_item_attrs
      expect(attrs[:item_type]).to eq("obligation_deduction")
      expect(attrs[:amount]).to    eq(-500)
    end

    it "does not save the snapshot yet (caller saves it)" do
      result = run
      expect(result.items.first.snapshot).to be_new_record
    end
  end

  context "when the obligation is paused" do
    let!(:obligation) do
      create(:employee_obligation,
             user: user, business: business,
             total_amount: 1000, remaining_amount: 1000,
             installment_amount: 200,
             start_month: 1, start_year: 2025, status: "paused")
    end

    it "skips the paused obligation" do
      result = run
      expect(result.total_amount).to eq(0)
      expect(result.items).to be_empty
    end
  end

  context "when auto_deduct is false" do
    let!(:obligation) do
      create(:employee_obligation, :manual_deduct,
             user: user, business: business,
             total_amount: 1000, remaining_amount: 1000, installment_amount: 200,
             start_month: 1, start_year: 2025)
    end

    it "skips the obligation" do
      result = run
      expect(result.total_amount).to eq(0)
    end
  end

  context "when an obligation deduction already exists for this period" do
    let!(:obligation) do
      create(:employee_obligation,
             user: user, business: business,
             total_amount: 1000, remaining_amount: 500,
             installment_amount: 200,
             start_month: 1, start_year: 2025)
    end

    before do
      ObligationDeduction.create!(
        employee_obligation: obligation,
        payroll_period:      period,
        deducted_amount:     200,
        remaining_before:    1000,
        remaining_after:     800
      )
    end

    it "skips the already-processed obligation" do
      result = run
      expect(result.items).to be_empty
    end
  end

  context "when remaining is less than the installment" do
    let!(:obligation) do
      create(:employee_obligation,
             user: user, business: business,
             total_amount: 1000, remaining_amount: 150,
             installment_amount: 500,
             start_month: 1, start_year: 2025)
    end

    it "deducts only the remaining amount" do
      result = run
      expect(result.total_amount).to eq(150)
      expect(result.items.first.snapshot.deducted_amount).to eq(150)
    end
  end

  context "with multiple obligations" do
    let!(:obligation1) do
      create(:employee_obligation,
             user: user, business: business,
             total_amount: 2000, remaining_amount: 2000, installment_amount: 300,
             start_month: 1, start_year: 2025)
    end

    let!(:obligation2) do
      create(:employee_obligation,
             user: user, business: business,
             total_amount: 500, remaining_amount: 500, installment_amount: 500,
             start_month: 3, start_year: 2025)
    end

    it "sums both installments" do
      result = run
      expect(result.total_amount).to eq(800)
      expect(result.items.size).to eq(2)
    end
  end
end
