require "rails_helper"

RSpec.describe Finance::Reports::BranchProfitability, type: :model do
  let(:business) { create(:business) }
  let(:branch)   { create(:branch, business: business) }
  let(:other)    { create(:branch, business: business) }
  let(:category) { create(:expense_category, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Dye", sku: "DYE-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:year)  { Date.current.year }
  let(:month) { Date.current.month }
  let(:actor) { create(:user, business: business) }
  let(:employee) { create(:user, business: business) }
  let(:cash_pm) { PaymentMethod.create!(business: business, name: "Cash", settlement_type: "cash", active: true) }

  # ShiftAssignment.active_during(from, to) matches on effective_from/to
  # overlapping the payroll period's own [start, end] — assignments must
  # start on/before the 1st of `month`/`year` to be picked up.
  let(:period_start) { Date.new(year, month, 1) }

  before do
    # Revenue 9000 — from a verified Daily Reconciliation (the single source of
    # truth for revenue), not the unused BranchRevenue manual-entry table.
    dr = DailyReconciliation.create!(
      branch: branch, business: business, state: "verified",
      opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
      verified_at: Date.current.to_time, verified_by_id: actor.id
    )
    TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                               collected_amount: 9000, refund_amount: 0)

    # Payroll gross = base 5000 + OT 300 + bonus 200 = 5500. PayrollPeriod is
    # business-wide (branch: nil) — matches production exactly: Payroll::PeriodGenerator
    # never sets a period's branch_id (see PayrollPeriod#branch: "retained for
    # historical data; new periods always nil"). Branch attribution instead comes
    # from the employee's ShiftAssignment active during the period, same source
    # Payroll::InsuranceExpenseGenerator already uses for its own payroll-derived cost.
    period = create(:payroll_period, business: business, period_year: year, period_month: month)
    create(:payroll_entry, payroll_period: period, user: employee, base_salary: 5000, total_overtime: 300, total_bonuses: 200, net_salary: 5500)
    create(:shift_assignment, user: employee, branch: branch, effective_from: period_start - 1.month, effective_to: nil)

    # Inventory CONSUMPTION = 10 * 12 = 120 (OUT / stock_issue)
    business.inventory_movements.create!(product: product, warehouse: warehouse, branch: branch,
      direction: "out", reason: "stock_issue", quantity: 10, unit_cost: 12, occurred_on: Date.current)
    # A purchase (IN / goods_receipt) must NOT count as cost
    business.inventory_movements.create!(product: product, warehouse: warehouse, branch: branch,
      direction: "in", reason: "goods_receipt", quantity: 5, unit_cost: 100, occurred_on: Date.current)

    # Direct branch expense 1000 (approved)
    create(:expense, :approved, business: business, branch: branch, amount: 1000, expense_date: Date.current)
    # Shared expense 200 split 50/50 -> 100 allocated to this branch
    shared = build(:expense, :approved, business: business, branch: nil, amount: 200, expense_date: Date.current,
                             distribution_method: "percentage")
    shared.expense_allocations.build(branch: branch, allocation_percentage: 50, allocated_amount: 100)
    shared.expense_allocations.build(branch: other, allocation_percentage: 50, allocated_amount: 100)
    shared.save!
  end

  subject(:rows) { described_class.new(business, year: year, month: month).call.rows }

  it "computes Net = Revenue - Payroll - Inventory consumption - Branch expenses" do
    row = rows.find { |r| r[:branch] == branch.name }
    expect(row[:revenue]).to   eq(9000)
    expect(row[:payroll]).to   eq(5500)
    expect(row[:inventory]).to eq(120)            # consumption only, excludes the 500 purchase
    expect(row[:expenses]).to  eq(1100)           # 1000 direct + 100 allocated share
    expect(row[:net]).to       eq(9000 - 5500 - 120 - 1100)  # 2280
  end

  it "reconciles the totals row to the sum of branch rows" do
    table = described_class.new(business, year: year, month: month).call
    %i[revenue payroll inventory expenses net].each do |col|
      expect(table.totals[col]).to eq(table.rows.sum { |r| r[col] })
    end
  end

  it "excludes draft/pending expenses from committed cost" do
    create(:expense, :pending, business: business, branch: branch, amount: 9999, expense_date: Date.current)
    row = described_class.new(business, year: year, month: month).call.rows.find { |r| r[:branch] == branch.name }
    expect(row[:expenses]).to eq(1100)
  end

  it "excludes revenue from an unverified daily reconciliation" do
    unverified = DailyReconciliation.create!(
      branch: other, business: business, state: "closed",
      opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current
    )
    TillSessionAmount.create!(daily_reconciliation: unverified, payment_method: cash_pm, payment_method_name: "Cash",
                               collected_amount: 5000, refund_amount: 0)

    row = described_class.new(business, year: year, month: month).call.rows.find { |r| r[:branch] == other.name }
    expect(row[:revenue]).to eq(0)
  end

  # Regression coverage for the "Salary Cost always shows 0" bug: the previous
  # implementation grouped payroll by `payroll_periods.branch_id`, a column that
  # is always nil on every period Payroll::PeriodGenerator creates (periods are
  # business-wide since the branch-membership refactor). The fixed query attributes
  # each PayrollEntry to a branch via the employee's ShiftAssignment during the
  # period instead — the same source Payroll::InsuranceExpenseGenerator already
  # uses for its own payroll-derived cost.
  describe "salary cost attribution" do
    it "includes salary cost when payroll exists for the period" do
      row = rows.find { |r| r[:branch] == branch.name }
      expect(row[:payroll]).to eq(5500)
    end

    it "respects month/year — a payroll entry in a different month is excluded" do
      other_month = Date.new(year, month, 1).next_month
      other_period = create(:payroll_period, business: business, period_year: other_month.year, period_month: other_month.month)
      create(:payroll_entry, payroll_period: other_period, user: create(:user, business: business),
             base_salary: 9999, total_overtime: 0, total_bonuses: 0, net_salary: 9999)

      row = rows.find { |r| r[:branch] == branch.name }
      expect(row[:payroll]).to eq(5500) # unchanged — the extra entry is a different month
    end

    it "respects branch_id — attributes each employee's salary to the branch they were assigned to during the period, not another branch" do
      other_employee = create(:user, business: business)
      period = PayrollPeriod.find_by!(business: business, period_year: year, period_month: month)
      create(:payroll_entry, payroll_period: period, user: other_employee, base_salary: 3000, total_overtime: 0, total_bonuses: 0, net_salary: 3000)
      create(:shift_assignment, user: other_employee, branch: other, effective_from: period_start - 1.month, effective_to: nil)

      table = described_class.new(business, year: year, month: month).call
      expect(table.rows.find { |r| r[:branch] == branch.name }[:payroll]).to eq(5500)
      expect(table.rows.find { |r| r[:branch] == other.name }[:payroll]).to eq(3000)
    end

    it "aggregates salary cost across all branches in the totals row (All Branches view)" do
      other_employee = create(:user, business: business)
      period = PayrollPeriod.find_by!(business: business, period_year: year, period_month: month)
      create(:payroll_entry, payroll_period: period, user: other_employee, base_salary: 3000, total_overtime: 0, total_bonuses: 0, net_salary: 3000)
      create(:shift_assignment, user: other_employee, branch: other, effective_from: period_start - 1.month, effective_to: nil)

      table = described_class.new(business, year: year, month: month).call
      expect(table.totals[:payroll]).to eq(5500 + 3000)
    end

    it "does not double-count payroll inside branch expenses" do
      row = rows.find { |r| r[:branch] == branch.name }
      # 1000 direct + 100 allocated share only — no trace of the 5500 payroll figure
      expect(row[:expenses]).to eq(1100)
    end

    it "reduces net profit by the salary cost (net profit changes when payroll is included)" do
      row = rows.find { |r| r[:branch] == branch.name }
      net_without_payroll = row[:revenue] - row[:inventory] - row[:expenses]
      expect(row[:net]).to eq(net_without_payroll - 5500)
      expect(row[:net]).to be < net_without_payroll
    end

    it "falls back to the business's first branch when an employee has no shift assignment during the period, instead of silently dropping the cost" do
      unassigned_employee = create(:user, business: business)
      period = PayrollPeriod.find_by!(business: business, period_year: year, period_month: month)
      create(:payroll_entry, payroll_period: period, user: unassigned_employee, base_salary: 750, total_overtime: 0, total_bonuses: 0, net_salary: 750)

      table = described_class.new(business, year: year, month: month).call
      expect(table.totals[:payroll]).to eq(5500 + 750) # nothing lost from the business-wide total
    end
  end

  # Branch Profitability only ever had meaningful data for branches that run
  # Daily Reconciliations (sales branches) — laundry/warehouse/headquarters/
  # maintenance/other branches never generated real revenue here anyway.
  # Same branch_type field/value ("sales") Daily Reconciliation's own branch
  # scoping already uses (Finance::DailyReconciliationsController#sales_branches).
  describe "sales-branch filtering" do
    let(:laundry) { create(:branch, business: business, branch_type: "laundry") }

    it "includes sales branches in the report" do
      expect(rows.map { |r| r[:branch] }).to include(branch.name)
    end

    it "excludes non-sales branches from the report entirely" do
      # Give the laundry branch its own revenue/expense/payroll so excluding
      # it is a real assertion, not just "it was never in the data".
      dr = DailyReconciliation.create!(
        branch: laundry, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: actor.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 4000, refund_amount: 0)
      create(:expense, :approved, business: business, branch: laundry, amount: 500, expense_date: Date.current)
      laundry_employee = create(:user, business: business)
      period = PayrollPeriod.find_by!(business: business, period_year: year, period_month: month)
      create(:payroll_entry, payroll_period: period, user: laundry_employee, base_salary: 2000, total_overtime: 0, total_bonuses: 0, net_salary: 2000)
      create(:shift_assignment, user: laundry_employee, branch: laundry, effective_from: period_start - 1.month, effective_to: nil)

      table = described_class.new(business, year: year, month: month).call
      expect(table.rows.map { |r| r[:branch] }).not_to include(laundry.name)
    end

    it "does not include a non-sales branch's revenue/expenses/payroll in the All Branches totals" do
      dr = DailyReconciliation.create!(
        branch: laundry, business: business, state: "verified",
        opened_at: Date.current.to_time, closed_at: Date.current.to_time, business_date: Date.current,
        verified_at: Date.current.to_time, verified_by_id: actor.id
      )
      TillSessionAmount.create!(daily_reconciliation: dr, payment_method: cash_pm, payment_method_name: "Cash",
                                 collected_amount: 4000, refund_amount: 0)
      create(:expense, :approved, business: business, branch: laundry, amount: 500, expense_date: Date.current)

      table_before = described_class.new(business, year: year, month: month).call
      # Totals must equal exactly the sales-branch rows from the shared setup
      # (branch: 9000 revenue / 1100 expenses; other: 0 revenue / 100 expenses,
      # its share of the shared expense) — the laundry branch's 4000 revenue /
      # 500 expense must not appear anywhere in these totals.
      expect(table_before.totals[:revenue]).to  eq(9000)
      expect(table_before.totals[:expenses]).to eq(1100 + 100)
    end

    it "keeps sales-branch payroll costs correct when a non-sales branch also has payroll" do
      laundry_employee = create(:user, business: business)
      period = PayrollPeriod.find_by!(business: business, period_year: year, period_month: month)
      create(:payroll_entry, payroll_period: period, user: laundry_employee, base_salary: 2000, total_overtime: 0, total_bonuses: 0, net_salary: 2000)
      create(:shift_assignment, user: laundry_employee, branch: laundry, effective_from: period_start - 1.month, effective_to: nil)

      row = rows.find { |r| r[:branch] == branch.name }
      expect(row[:payroll]).to eq(5500) # unaffected by the laundry employee's payroll
    end

    it "keeps the profitability formula unchanged for the remaining sales branches" do
      row = rows.find { |r| r[:branch] == branch.name }
      expect(row[:net]).to eq(row[:revenue] - row[:payroll] - row[:inventory] - row[:expenses])
    end
  end

  # The standard laundry/towel cost a sales branch was charged for towels it
  # sent to be washed — sourced from Laundry::BranchTowelConsumptionReport
  # (the same report the Laundry module's own UI displays), folded into the
  # existing Branch Expenses total. Construction mirrors
  # spec/services/laundry/branch_towel_consumption_report_spec.rb exactly,
  # since that's the single place this figure is computed.
  describe "laundry/towel cost" do
    let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
    let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }

    def fund(target_branch, status, quantity)
      Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: target_branch, status: status,
                                                     adjustment_quantity: quantity, reason: "test setup")
    end

    def transfer_and_receive!(source:, quantity:, confirmed:, received_at: nil)
      created = Laundry::TowelTransferCreator.create(actor: actor, params: {
        source_branch_id: source.id, destination_branch_id: laundry_branch.id, towel_status: "dirty",
        items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: quantity } ]
      })
      transfer = created.transfer
      Laundry::TowelTransferCreator.new(transfer.reload).dispatch(actor: actor)
      item_id = transfer.reload.items.first.id
      Laundry::TowelTransferCreator.new(transfer).receive(actor: actor, confirmed_quantities: { item_id => confirmed })
      transfer.update_column(:received_at, received_at) if received_at
      transfer
    end

    before do
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 5, effective_from: 1.year.ago)
    end

    it "attributes standard laundry cost to the sales branch that sent the towels, inside Branch Expenses" do
      fund(branch, "clean", 100)
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100)

      row = rows.find { |r| r[:branch] == branch.name }
      # 1100 existing (direct + allocated) + 500 laundry (100 towels * 5/towel)
      expect(row[:expenses]).to eq(1100 + 500)
    end

    it "reduces net profit by exactly the laundry cost" do
      fund(branch, "clean", 100)

      net_before = described_class.new(business, year: year, month: month).call.rows.find { |r| r[:branch] == branch.name }[:net]
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100)
      net_after = described_class.new(business, year: year, month: month).call.rows.find { |r| r[:branch] == branch.name }[:net]

      expect(net_after).to eq(net_before - 500)
    end

    it "leaves a sales branch with no laundry activity unaffected" do
      fund(branch, "clean", 100)
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100)

      row = rows.find { |r| r[:branch] == other.name }
      expect(row[:expenses]).to eq(100) # only its 100 allocated share of the shared expense
    end

    it "aggregates laundry cost correctly across branches in the All Branches totals" do
      fund(branch, "clean", 100)
      fund(other, "clean", 40)
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100)
      transfer_and_receive!(source: other, quantity: 40, confirmed: 40)

      table = described_class.new(business, year: year, month: month).call
      # existing 1100 + 100 direct/allocated, plus 500 + 200 laundry cost
      expect(table.totals[:expenses]).to eq(1100 + 100 + 500 + 200)
    end

    it "never attributes laundry cost to the Laundry branch itself, and the Laundry branch never appears as a row" do
      fund(branch, "clean", 100)
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100)

      table = described_class.new(business, year: year, month: month).call
      expect(table.rows.map { |r| r[:branch] }).not_to include(laundry_branch.name)
    end

    it "respects month/year — a towel receipt in a different month is excluded" do
      fund(branch, "clean", 100)
      other_month_date = Date.new(year, month, 1).next_month + 5.days
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100, received_at: other_month_date)

      row = rows.find { |r| r[:branch] == branch.name }
      expect(row[:expenses]).to eq(1100) # laundry receipt falls outside this month, excluded
    end

    it "does not double-count laundry cost against inventory or payroll" do
      fund(branch, "clean", 100)
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100)

      row = rows.find { |r| r[:branch] == branch.name }
      expect(row[:inventory]).to eq(120) # unchanged — no trace of the 500 laundry cost
      expect(row[:payroll]).to eq(5500)  # unchanged
    end

    it "keeps the profitability formula (Net = Revenue - Payroll - Inventory - Expenses) mathematically correct with laundry cost included" do
      fund(branch, "clean", 100)
      transfer_and_receive!(source: branch, quantity: 100, confirmed: 100)

      row = rows.find { |r| r[:branch] == branch.name }
      expect(row[:net]).to eq(row[:revenue] - row[:payroll] - row[:inventory] - row[:expenses])
    end
  end
end
