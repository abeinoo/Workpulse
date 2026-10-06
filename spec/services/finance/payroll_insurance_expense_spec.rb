require "rails_helper"

# Milestone 2 — Finance & Sales Expenses, M4: the Finance-owned Social
# Insurance Expense for a finalized payroll period (moved unchanged from the
# former Payroll::InsuranceExpenseGenerator). The cost arrives as data, so
# these examples drive the service directly with a payload — no payroll
# entries are needed. End-to-end behaviour through Payroll::Approver /
# Reopener stays pinned by insurance_expense_refresh_spec (FS-D1),
# insurance_expense_category_spec (FS-D2) and the finance_sales
# characterization.
RSpec.describe Finance::PayrollInsuranceExpense do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:branch_a) { create(:branch, business: business) }
  let!(:branch_b) { create(:branch, business: business) }
  let!(:branch_c) { create(:branch, business: business) }
  let(:period) do
    create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "finalized")
  end

  def record(total:, by_branch:, for_period: period)
    described_class.record(period: for_period, actor: owner, total: total.to_d, by_branch: by_branch)
  end

  def active_expenses = Expense.where(source_payroll_period: period, voided_at: nil)

  describe ".record" do
    it "creates an approved Social Insurance expense for a single branch, with a reference and an audit" do
      result = record(total: 100, by_branch: { branch_b.id => 100.to_d })

      expect(result).to be_ok
      expect(result.expense).to have_attributes(
        amount: 100, status: "approved", branch_id: branch_b.id, expense_date: period.period_end,
        created_by_id: owner.id, approved_by_id: owner.id, deduct_from_balance: false,
        source_payroll_period_id: period.id
      )
      expect(result.expense.reference_number).to be_present
      expect(result.expense.expense_category.name).to eq("Social Insurance")
      expect(AuditLog.where(auditable: result.expense, action: "insurance_expense_generated")).to exist
    end

    it "splits several branches by percentage, using the given amounts and summing to exactly 100" do
      expense = record(total: 100, by_branch: { branch_a.id => 33.33.to_d, branch_b.id => 33.33.to_d,
                                                branch_c.id => 33.34.to_d }).expense

      expect(expense).to have_attributes(branch_id: nil, distribution_method: "percentage")
      expect(expense.expense_allocations.map { |a| [ a.branch_id, a.allocated_amount ] })
        .to contain_exactly([ branch_a.id, 33.33 ], [ branch_b.id, 33.33 ], [ branch_c.id, 33.34 ])
      expect(expense.expense_allocations.sum(&:allocation_percentage)).to eq(100)
    end

    it "creates nothing for a zero total" do
      expect { expect(record(total: 0, by_branch: {})).to be_ok }.not_to change(Expense, :count)
    end

    it "is idempotent while an active expense exists" do
      record(total: 100, by_branch: { branch_a.id => 100.to_d })

      result = nil
      expect { result = record(total: 300, by_branch: { branch_a.id => 300.to_d }) }.not_to change(Expense, :count)
      expect(result).to be_ok
      expect(active_expenses.sole.amount).to eq(100)
    end

    it "reuses an existing category regardless of case (FS-D2)" do
      existing = create(:expense_category, business: business, name: "SOCIAL insurance")

      expect { record(total: 100, by_branch: { branch_a.id => 100.to_d }) }.not_to change(ExpenseCategory, :count)
      expect(active_expenses.sole.expense_category).to eq(existing)
    end

    it "numbers each period's expense from the Finance expense sequence" do
      other_period = create(:payroll_period, business: business, period_year: 2026, period_month: 7, status: "finalized")

      first  = record(total: 100, by_branch: { branch_a.id => 100.to_d }).expense
      second = record(total: 50, by_branch: { branch_a.id => 50.to_d }, for_period: other_period).expense

      expect([ first.reference_number, second.reference_number ].uniq.size).to eq(2)
    end
  end

  describe ".void_for" do
    it "voids and cancels the active expense, keeping it as history, with an audit" do
      expense = record(total: 100, by_branch: { branch_a.id => 100.to_d }).expense

      described_class.void_for(period: period, actor: owner, reason: "Fix")

      expect(expense.reload).to have_attributes(
        status: "cancelled", voided_by_id: owner.id, amount: 100,
        void_reason: I18n.t("payroll.insurance_expense_void_reason", reason: "Fix")
      )
      expect(expense.voided_at).to be_present
      expect(AuditLog.where(auditable: expense, action: "insurance_expense_voided")).to exist
    end

    it "lets the next record create a fresh expense" do
      record(total: 100, by_branch: { branch_a.id => 100.to_d })
      described_class.void_for(period: period, actor: owner, reason: "Fix")

      record(total: 300, by_branch: { branch_a.id => 300.to_d })

      expect(active_expenses.sole.amount).to eq(300)
      expect(Expense.where(source_payroll_period: period).count).to eq(2)
    end

    it "is a no-op when there is no active expense" do
      expect { described_class.void_for(period: period, actor: owner, reason: "Fix") }.not_to change(AuditLog, :count)
    end
  end

  it "reads no payroll entries or shift assignments (the cost is supplied by Payroll)" do
    source = File.read(Rails.root.join("app/services/finance/payroll_insurance_expense.rb"))
    code   = source.each_line.reject { |line| line.lstrip.start_with?("#") }.join

    expect(code).not_to match(/payroll_entries|PayrollEntry|ShiftAssignment/)
  end
end
