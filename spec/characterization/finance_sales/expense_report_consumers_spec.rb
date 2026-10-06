require "rails_helper"

# Characterization (Milestone 2 — Finance & Sales Expenses, M1) — CURRENT rule
# by which Finance expense reports consume expenses: they count status
# "approved" only (default statuses) and never look at voided_at. This is why
# FS-D1 voids a stale payroll insurance expense AND sets it to "cancelled".
# Report layouts, branch profitability and expense sources are covered in
# spec/services/finance/reports/ and spec/requests/finance/reports_*.
RSpec.describe "Characterization: expense report consumers" do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :owner, business: business) }
  let!(:branch)  { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business, name: "Rent") }
  let(:june)     { Date.new(2026, 6, 15) }

  def summary = Finance::Reports::ExpenseSummary.new(business, group_by: :category, from: june.beginning_of_month, to: june.end_of_month).call
  def trend   = Finance::Reports::ExpenseTrend.new(business, from: june.beginning_of_month, to: june.end_of_month).call

  it "counts approved expenses only (not draft, pending, rejected or cancelled)" do
    create(:expense, :approved, business: business, branch: branch, expense_category: category, amount: 100, expense_date: june)
    %w[draft pending_approval rejected cancelled].each do |status|
      create(:expense, business: business, branch: branch, expense_category: category, amount: 900, expense_date: june, status: status)
    end

    expect(summary.totals).to eq(count: 1, total: 100)
    expect(trend.totals).to eq(count: 1, total: 100)
  end

  it "counts the payroll insurance expense while active, and only its replacement after reopen/re-finalize (FS-D1)" do
    period = create(:payroll_period, business: business, period_year: 2026, period_month: 6, status: "branch_review_completed")
    entry  = create(:payroll_entry, payroll_period: period, user: create(:user, business: business),
                                    insured: true, employer_insurance_amount: 100)

    Payroll::Approver.advance(period: period, by: owner)
    expect(summary.totals[:total]).to eq(100)

    Payroll::Reopener.call(period: period.reload, by: owner, reason: "Correct insurance")
    expect(summary.totals[:total]).to eq(0)

    entry.update_columns(employer_insurance_amount: 300)
    Payroll::Approver.advance(period: period.reload, by: owner)
    expect(summary.totals).to eq(count: 1, total: 300)
  end
end
