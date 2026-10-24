require "rails_helper"

# Branch narrowing of Expenses by Category / by Type (and their trend chart):
# the branch's own expenses at their amount plus its allocated share of each
# shared expense — the same attribution the by-branch grouping has always used.
RSpec.describe "Finance::Reports expense summary / trend — branch filter" do
  let(:business) { create(:business) }
  let(:north)    { create(:branch, business: business, name: "North") }
  let(:south)    { create(:branch, business: business, name: "South") }
  let(:rent)     { create(:expense_category, business: business, name: "Rent") }
  let(:supplies) { create(:expense_category, business: business, name: "Supplies") }
  let(:cleaning) { create(:expense_type, business: business, expense_category: supplies, name: "Cleaning") }
  let(:from)     { Date.new(2026, 9, 1) }
  let(:to)       { Date.new(2026, 10, 31) }
  let(:sept)     { Date.new(2026, 9, 15) }
  let(:oct)      { Date.new(2026, 10, 5) }

  def shared_expense(category:, amount:, date:, shares:, type: nil)
    expense = build(:expense, :approved, business: business, branch: nil, expense_category: category, expense_type: type,
                                         amount: amount, expense_date: date, distribution_method: "manual")
    shares.each do |branch, share|
      expense.expense_allocations.build(branch: branch, allocated_amount: share, allocation_percentage: share * 100.0 / amount)
    end
    expense.save!
    expense
  end

  def summary(group_by, branch_id: nil)
    Finance::Reports::ExpenseSummary.new(business, group_by: group_by, from: from, to: to, branch_id: branch_id).call
  end

  def by_label(table) = table.rows.to_h { |r| [ r[:label], [ r[:count], r[:total].to_d ] ] }

  before do
    create(:expense, :approved, business: business, branch: north, expense_category: rent, amount: 1000, expense_date: sept)
    create(:expense, :approved, business: business, branch: south, expense_category: rent, amount: 700, expense_date: oct)
    create(:expense, :approved, business: business, branch: north, expense_category: supplies, expense_type: cleaning,
                                amount: 50, expense_date: oct)
    shared_expense(category: supplies, type: cleaning, amount: 300, date: oct, shares: { north => 120, south => 180 })
    # Outside the period / not approved — never counted.
    create(:expense, :approved, business: business, branch: north, expense_category: rent, amount: 9999, expense_date: Date.new(2026, 8, 31))
    create(:expense, :pending, business: business, branch: north, expense_category: rent, amount: 8888, expense_date: oct)
  end

  it "is business-wide without a branch, a shared expense counted once in full (unchanged)" do
    expect(by_label(summary(:category))).to eq("Rent" => [ 2, 1700 ], "Supplies" => [ 2, 350 ])
  end

  it "narrows by category to a branch's own expenses plus its allocated share" do
    expect(by_label(summary(:category, branch_id: north.id))).to eq("Rent" => [ 1, 1000 ], "Supplies" => [ 2, 170 ])
    expect(by_label(summary(:category, branch_id: south.id))).to eq("Rent" => [ 1, 700 ], "Supplies" => [ 1, 180 ])
  end

  it "narrows by type the same way" do
    untyped = I18n.t("finance.reports.untyped")
    expect(by_label(summary(:type, branch_id: north.id))).to eq(untyped => [ 1, 1000 ], "Cleaning" => [ 2, 170 ])
    expect(by_label(summary(:type, branch_id: south.id))).to eq(untyped => [ 1, 700 ], "Cleaning" => [ 1, 180 ])
  end

  # Allocations are grouped by the shared EXPENSE's own column (category / type),
  # and their keys — nil (untyped) included — merge with the branch's direct rows.
  it "groups a branch's allocations by the shared expense's own column, merging an untyped share with direct untyped rows" do
    shared_expense(category: rent, amount: 200, date: oct, shares: { north => 50, south => 150 }) # untyped
    untyped = I18n.t("finance.reports.untyped")

    expect(by_label(summary(:type, branch_id: north.id))).to eq(untyped => [ 2, 1050 ], "Cleaning" => [ 2, 170 ])
    expect(by_label(summary(:category, branch_id: south.id))).to eq("Rent" => [ 2, 850 ], "Supplies" => [ 1, 180 ])
    expect(by_label(summary(:category))).to eq("Rent" => [ 3, 1900 ], "Supplies" => [ 2, 350 ]) # counted once in full
  end

  it "never counts a shared expense in full against every branch: branch totals add up to the business total" do
    branch_total = [ north, south ].sum { |b| summary(:category, branch_id: b.id).totals[:total] }
    expect(branch_total).to eq(summary(:category).totals[:total])
  end

  it "matches the by-branch report for the same branch" do
    by_branch = by_label(summary(:branch))
    expect(summary(:category, branch_id: north.id).totals[:total].to_d).to eq(by_branch["North"].last)
  end

  it "leaves out an expense with neither a branch nor allocations under a branch filter" do
    orphan = shared_expense(category: rent, amount: 400, date: oct, shares: { north => 400 })
    orphan.expense_allocations.delete_all
    orphan.update_columns(is_shared: false)

    expect(summary(:category).totals[:total].to_d).to eq(2450)
    expect(summary(:category, branch_id: north.id).totals[:total].to_d).to eq(1170)
  end

  it "returns no rows for a branch with no expenses" do
    empty = create(:branch, business: business)
    table = summary(:category, branch_id: empty.id)
    expect(table.rows).to be_empty
    expect(table.totals).to eq(count: 0, total: 0)
  end

  describe Finance::Reports::ExpenseTrend do
    def trend(branch_id: nil)
      described_class.new(business, from: from, to: to, branch_id: branch_id).call
                     .rows.map { |r| [ r[:count], r[:total].to_d ] }
    end

    it "is business-wide without a branch (unchanged)" do
      expect(trend).to eq([ [ 1, 1000 ], [ 3, 1050 ] ])
    end

    it "narrows each month to the branch's own expenses plus its allocated share" do
      expect(trend(branch_id: north.id)).to eq([ [ 1, 1000 ], [ 2, 170 ] ])
      expect(trend(branch_id: south.id)).to eq([ [ 2, 880 ] ])
    end
  end
end
