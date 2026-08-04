require "rails_helper"

RSpec.describe Payroll::PeriodFinancialSummary do
  let(:business) { create(:business) }
  let(:period)   { create(:payroll_period, business: business) }
  let(:employee) { create(:user, business: business) }

  let(:entry) do
    create(:payroll_entry, payroll_period: period, user: employee, base_salary: 5_000.0)
  end

  let(:entries) { PayrollEntry.where(payroll_period: period) }

  subject(:summary) { described_class.new(entries) }

  describe "Gross Payroll" do
    it "equals base_salary alone when there are no line items" do
      entry
      expect(summary.gross_payroll).to eq(5_000.0)
    end

    it "equals base_salary plus the sum of every positive, financially-active line item" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 300.0, review_status: "approved")
      create(:payroll_line_item, payroll_entry: entry, item_type: "commission", amount: 200.0, review_status: "approved")

      expect(summary.gross_payroll).to eq(5_500.0)
    end

    it "automatically includes a brand-new positive item_type with no code changes" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
             amount: 150.0, review_status: "approved")

      expect(summary.gross_payroll).to eq(5_150.0)
    end

    it "excludes a pending_review item" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "commission", amount: 200.0, review_status: "pending_review")
      expect(summary.gross_payroll).to eq(5_000.0)
    end

    it "excludes a rejected item" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "commission", amount: 200.0, review_status: "rejected")
      expect(summary.gross_payroll).to eq(5_000.0)
    end

    it "sums across multiple entries in the period" do
      entry
      other_entry = create(:payroll_entry, payroll_period: period, user: create(:user, business: business), base_salary: 3_000.0)
      create(:payroll_line_item, payroll_entry: other_entry, item_type: "overtime", amount: 100.0, review_status: "approved")

      expect(summary.gross_payroll).to eq(5_000.0 + 3_000.0 + 100.0)
    end
  end

  describe "Total Deductions" do
    it "equals the absolute value of every negative, financially-active line item" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved")
      create(:payroll_line_item, payroll_entry: entry, item_type: "advance_deduction", amount: -50.0, review_status: "approved")

      expect(summary.total_deductions).to eq(150.0)
    end

    it "automatically includes a brand-new negative item_type with no code changes" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "obligation_deduction",
             amount: -75.0, review_status: "approved")

      expect(summary.total_deductions).to eq(75.0)
    end

    it "excludes a waived deduction" do
      entry
      li = create(:payroll_line_item, payroll_entry: entry, item_type: "manual_deduction",
                  amount: -100.0, review_status: "approved", source_type: "PayrollAdjustment", source_id: 1)
      li.update!(deduction_waived: true)

      expect(summary.total_deductions).to eq(0.0)
    end

    it "excludes a pending_review deduction" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "manual_deduction", amount: -100.0, review_status: "pending_review")
      expect(summary.total_deductions).to eq(0.0)
    end

    it "folds an already_paid bonus's amount into Total Deductions" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
             amount: 400.0, review_status: "approved", already_paid: true)

      expect(summary.total_deductions).to eq(400.0)
    end

    it "does not fold a NOT-already_paid bonus into Total Deductions" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
             amount: 400.0, review_status: "approved", already_paid: false)

      expect(summary.total_deductions).to eq(0.0)
    end
  end

  describe "Net Payroll" do
    it "always equals Gross Payroll minus Total Deductions" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 300.0, review_status: "approved")
      create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved")

      expect(summary.net_payroll).to eq(summary.gross_payroll - summary.total_deductions)
      expect(summary.net_payroll).to eq(5_200.0)
    end

    it "matches entry.net_salary exactly, including the already_paid case" do
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 300.0, review_status: "approved")
      create(:payroll_line_item, payroll_entry: entry, item_type: "cash_incentive",
             amount: 400.0, review_status: "approved", already_paid: true)
      create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved")
      entry.recalculate_totals!

      expect(summary.net_payroll).to eq(entry.reload.net_salary)
    end
  end

  describe "#gross_breakdown" do
    it "includes Base Salary as its own category" do
      entry
      base_category = summary.gross_breakdown.find { |c| c.item_type == "base_salary" }
      expect(base_category.amount).to eq(5_000.0)
    end

    it "groups positive line items by item_type dynamically" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 100.0, review_status: "approved")
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 50.0, review_status: "approved")
      create(:payroll_line_item, payroll_entry: entry, item_type: "commission", amount: 200.0, review_status: "approved")

      overtime = summary.gross_breakdown.find { |c| c.item_type == "overtime" }
      commission = summary.gross_breakdown.find { |c| c.item_type == "commission" }
      expect(overtime.amount).to eq(150.0)
      expect(commission.amount).to eq(200.0)
    end

    it "never includes a negative-amount item_type" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved")
      expect(summary.gross_breakdown.map(&:item_type)).not_to include("late_penalty")
    end
  end

  describe "#deduction_breakdown" do
    it "groups negative line items by item_type dynamically" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "late_penalty", amount: -100.0, review_status: "approved")
      create(:payroll_line_item, payroll_entry: entry, item_type: "insurance_deduction", amount: -60.0, review_status: "approved")

      types = summary.deduction_breakdown.map(&:item_type)
      expect(types).to include("late_penalty", "insurance_deduction")
    end

    it "includes an already_paid category only when present" do
      entry
      expect(described_class.new(entries).deduction_breakdown.map(&:item_type)).not_to include("already_paid")

      create(:payroll_line_item, payroll_entry: entry, item_type: "commission",
             amount: 300.0, review_status: "approved", already_paid: true)
      already_paid = described_class.new(entries).deduction_breakdown.find { |c| c.item_type == "already_paid" }
      expect(already_paid.amount).to eq(300.0)
    end

    it "never includes a positive-amount item_type" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 100.0, review_status: "approved")
      expect(summary.deduction_breakdown.map(&:item_type)).not_to include("overtime")
    end
  end
end
