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

  describe "join fan-out regression" do
    # Regression coverage for a real production bug: PayrollPeriodsController#show
    # builds @entries with `.includes(:user, :payroll_line_items).order("users.first_name, ...")`
    # for its own display purposes, then hands that relation to this service.
    # Calling `.sum(:base_salary)` directly on a relation like that makes
    # ActiveRecord silently convert the `includes` into a LEFT OUTER JOIN
    # against payroll_line_items, fanning each entry out once per line item
    # and multiplying its base_salary accordingly. These specs build the
    # exact same includes/order-laden relation the controller does and assert
    # base salary totals stay correct regardless of how many line items exist.
    def entries_with_includes
      PayrollEntry.where(payroll_period: period)
        .includes(:user, :payroll_line_items)
        .order("users.first_name, users.last_name")
    end

    it "does not duplicate base salary for one employee with a single line item" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 100.0, review_status: "approved")

      plain_summary    = described_class.new(entries)
      included_summary = described_class.new(entries_with_includes)

      expect(included_summary.gross_payroll).to eq(plain_summary.gross_payroll)
      expect(included_summary.gross_payroll).to eq(5_100.0)
    end

    it "does not duplicate base salary for one employee with ten line items" do
      entry
      10.times do |i|
        create(:payroll_line_item, payroll_entry: entry, item_type: "commission", amount: 10.0 + i, review_status: "approved")
      end

      plain_summary    = described_class.new(entries)
      included_summary = described_class.new(entries_with_includes)

      expect(included_summary.gross_payroll).to eq(plain_summary.gross_payroll)
      # base_salary (5_000) must appear exactly once, regardless of 10 line items existing.
      base_category = included_summary.gross_breakdown.find { |c| c.item_type == "base_salary" }
      expect(base_category.amount).to eq(5_000.0)
    end

    it "does not duplicate base salary across multiple employees with differing line-item counts" do
      entry # employee A: base 5_000, 0 line items so far
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 200.0, review_status: "approved")

      employee_b = create(:user, business: business)
      entry_b = create(:payroll_entry, payroll_period: period, user: employee_b, base_salary: 3_000.0)
      5.times do
        create(:payroll_line_item, payroll_entry: entry_b, item_type: "commission", amount: 20.0, review_status: "approved")
      end

      employee_c = create(:user, business: business)
      entry_c = create(:payroll_entry, payroll_period: period, user: employee_c, base_salary: 4_000.0)
      # employee C has zero line items.

      plain_summary    = described_class.new(entries)
      included_summary = described_class.new(entries_with_includes)

      expected_base  = 5_000.0 + 3_000.0 + 4_000.0
      expected_gross = expected_base + 200.0 + (5 * 20.0)

      expect(included_summary.gross_payroll).to eq(plain_summary.gross_payroll)
      expect(included_summary.gross_payroll).to eq(expected_gross)

      base_category = included_summary.gross_breakdown.find { |c| c.item_type == "base_salary" }
      expect(base_category.amount).to eq(expected_base)
    end

    it "produces the exact same base salary total whether entries come loaded, unloaded, or as a plain array" do
      entry
      create(:payroll_line_item, payroll_entry: entry, item_type: "overtime", amount: 300.0, review_status: "approved")
      other_entry = create(:payroll_entry, payroll_period: period, user: create(:user, business: business), base_salary: 2_500.0)
      3.times { create(:payroll_line_item, payroll_entry: other_entry, item_type: "commission", amount: 10.0, review_status: "approved") }

      unloaded = entries_with_includes
      loaded   = entries_with_includes.load
      as_array = entries_with_includes.to_a

      totals = [ unloaded, loaded, as_array ].map { |scope| described_class.new(scope).gross_payroll }

      expect(totals.uniq.size).to eq(1)
      expect(totals.first).to eq(5_000.0 + 300.0 + 2_500.0 + 30.0)
    end
  end
end
