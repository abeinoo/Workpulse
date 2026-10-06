require "rails_helper"

RSpec.describe Finance::Reports::ExpenseDetails, type: :model do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:other)     { create(:branch, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Dye", sku: "DYE-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:year)  { Date.current.year }
  let(:month) { Date.current.month }
  let(:employee) { create(:user, business: business) }
  let(:actor) { create(:user, business: business) }
  let(:period_start) { Date.new(year, month, 1) }

  before do
    period = create(:payroll_period, business: business, period_year: year, period_month: month)
    create(:payroll_entry, payroll_period: period, user: employee,
           base_salary: 5000, total_overtime: 300, total_bonuses: 200, total_deductions: 150, net_salary: 5350)
    create(:shift_assignment, user: employee, branch: branch, effective_from: period_start - 1.month, effective_to: nil)

    business.inventory_movements.create!(product: product, warehouse: warehouse, branch: branch,
      direction: "out", reason: "stock_issue", quantity: 10, unit_cost: 12, occurred_on: Date.current)
    business.inventory_movements.create!(product: product, warehouse: warehouse, branch: branch,
      direction: "in", reason: "goods_receipt", quantity: 5, unit_cost: 100, occurred_on: Date.current)

    create(:expense, :approved, business: business, branch: branch, amount: 1000, expense_date: Date.current)
    shared = build(:expense, :approved, business: business, branch: nil, amount: 200, expense_date: Date.current,
                             distribution_method: "percentage")
    shared.expense_allocations.build(branch: branch, allocation_percentage: 50, allocated_amount: 100)
    shared.expense_allocations.build(branch: other, allocation_percentage: 50, allocated_amount: 100)
    shared.save!
  end

  subject(:result) { described_class.new(business, year: year, month: month).call }

  def section(key) = result.sections.find { |s| s.key == key }

  describe "section totals equal ExpenseSources' coarse figures" do
    it "payroll section total equals payroll_costs" do
      sources = Finance::Reports::ExpenseSources.new(business, year: year, month: month)
      expect(section(:payroll).total).to eq(sources.payroll_costs.values.sum)
    end

    it "inventory section total equals inventory_costs" do
      sources = Finance::Reports::ExpenseSources.new(business, year: year, month: month)
      expect(section(:inventory).total).to eq(sources.inventory_costs.values.sum)
    end

    it "branch_expenses section total equals direct_expenses" do
      sources = Finance::Reports::ExpenseSources.new(business, year: year, month: month)
      expect(section(:branch_expenses).total).to eq(sources.direct_expenses.values.sum)
    end

    it "shared_expenses section total equals allocated_expenses" do
      sources = Finance::Reports::ExpenseSources.new(business, year: year, month: month)
      expect(section(:shared_expenses).total).to eq(sources.allocated_expenses.values.sum)
    end
  end

  describe "reconciliation" do
    it "matches Branch Profitability's total for all sales branches" do
      bp = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.totals
      expect(result.reconciliation.report_total).to eq(bp[:payroll] + bp[:inventory] + bp[:expenses])
      expect(result.reconciliation).to be_matches
    end

    it "matches Branch Profitability's total for a single branch filter" do
      scoped = described_class.new(business, year: year, month: month, branch_id: branch.id).call
      bp_row = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.rows
        .find { |r| r[:branch] == branch.name }

      expect(scoped.reconciliation.report_total).to eq(bp_row[:payroll] + bp_row[:inventory] + bp_row[:expenses])
      expect(scoped.reconciliation).to be_matches
    end

    it "still matches for a branch with only its allocated share of a shared expense" do
      scoped = described_class.new(business, year: year, month: month, branch_id: other.id).call
      bp_row = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.rows
        .find { |r| r[:branch] == other.name }

      expect(scoped.reconciliation.report_total).to eq(bp_row[:payroll] + bp_row[:inventory] + bp_row[:expenses])
    end
  end

  describe "employee payroll rows — gross vs net" do
    it "sums gross (base+overtime+bonus) to the section total, but net_salary does not" do
      rows = section(:payroll).groups.find { |g| g.branch_id == branch.id }.rows
      expect(rows.sum { |r| r[:gross] }).to eq(section(:payroll).total)
      expect(rows.sum { |r| r[:net_salary] }).not_to eq(section(:payroll).total)
      expect(rows.first[:net_salary]).to eq(5350)
    end
  end

  describe "insurance-generated expense (system-generated, payroll-derived)" do
    it "appears once in branch_expenses/shared_expenses, is tagged system_generated, is absent from payroll, and reconciliation still holds" do
      period = PayrollPeriod.find_by!(business: business, period_year: year, period_month: month)
      entry = PayrollEntry.find_by!(payroll_period: period, user: employee)
      entry.update!(insured: true, employer_insurance_amount: 300)

      cost      = Payroll::EmployerInsuranceCost.for(period)
      generated = Finance::PayrollInsuranceExpense.record(period: period, actor: actor,
                                                          total: cost.total, by_branch: cost.by_branch)
      expect(generated).to be_ok
      expect(generated.expense).to be_present

      scoped = described_class.new(business, year: year, month: month).call
      all_rows = scoped.sections.flat_map { |s| s.groups.flat_map(&:rows) }
      insurance_rows = all_rows.select { |r| r[:reference] == generated.expense.reference_number }

      expect(insurance_rows.size).to eq(1)
      expect(insurance_rows.first[:system_generated]).to be true

      payroll_gross_sum = scoped.sections.find { |s| s.key == :payroll }.groups.flat_map(&:rows).sum { |r| r[:gross] }
      expect(payroll_gross_sum).to eq(5500) # unaffected by the 300 insurance amount

      bp = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.totals
      expect(scoped.reconciliation.report_total).to eq(bp[:payroll] + bp[:inventory] + bp[:expenses])
      expect(scoped.reconciliation).to be_matches
    end
  end

  describe "recurring-generated expense" do
    it "is counted once inside branch_expenses (not a separate bucket) and reflected in recurring_note without inflating the grand total" do
      recurring = create(:recurring_expense, business: business, branch: branch, amount: 400)
      create(:expense, :approved, business: business, branch: branch, amount: 400, expense_date: Date.current,
             source_recurring_expense: recurring)

      scoped = described_class.new(business, year: year, month: month).call
      branch_expense_rows = scoped.sections.find { |s| s.key == :branch_expenses }.groups
        .find { |g| g.branch_id == branch.id }.rows
      expect(branch_expense_rows.count { |r| r[:reference].present? }).to be >= 1
      expect(scoped.recurring_note.generated_this_period_amount).to eq(400)

      # Not double-counted: branch_expenses total is direct_expenses (1000 original + 400 recurring), not +800.
      sources = Finance::Reports::ExpenseSources.new(business, year: year, month: month)
      expect(scoped.sections.find { |s| s.key == :branch_expenses }.total).to eq(sources.direct_expenses.values.sum)

      bp = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.totals
      expect(scoped.reconciliation.report_total).to eq(bp[:payroll] + bp[:inventory] + bp[:expenses])
      expect(scoped.reconciliation).to be_matches
    end
  end

  describe "expense_type_id filter" do
    it "narrows only branch_expenses/shared_expenses; payroll/inventory/laundry stay unfiltered" do
      type = create(:expense_type, business: business, expense_category: business.expense_categories.first || create(:expense_category, business: business))
      unfiltered = described_class.new(business, year: year, month: month).call
      filtered   = described_class.new(business, year: year, month: month, expense_type_id: type.id).call

      expect(filtered.sections.find { |s| s.key == :payroll }.total).to eq(unfiltered.sections.find { |s| s.key == :payroll }.total)
      expect(filtered.sections.find { |s| s.key == :inventory }.total).to eq(unfiltered.sections.find { |s| s.key == :inventory }.total)
      # No expense has this brand-new type, so both Expense-backed sections narrow to zero.
      expect(filtered.sections.find { |s| s.key == :branch_expenses }.total).to eq(0)
      expect(filtered.sections.find { |s| s.key == :shared_expenses }.total).to eq(0)
    end
  end

  describe "branch filter" do
    let(:laundry) { create(:branch, business: business, branch_type: "laundry") }

    it "excludes the laundry branch as a row, but includes a sales branch's attributed laundry cost, and still reconciles" do
      towel_type = business.towel_types.create!(name: "Bath Towel")
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 5, effective_from: 1.year.ago)
      Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: branch, status: "clean",
                                                     adjustment_quantity: 100, reason: "test setup")
      created = Laundry::TowelTransferCreator.create(actor: actor, params: {
        source_branch_id: branch.id, destination_branch_id: laundry.id, towel_status: "dirty",
        items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: 100 } ]
      })
      transfer = created.transfer
      Laundry::TowelTransferCreator.new(transfer.reload).dispatch(actor: actor)
      item_id = transfer.reload.items.first.id
      Laundry::TowelTransferCreator.new(transfer).receive(actor: actor, confirmed_quantities: { item_id => 100 })

      scoped = described_class.new(business, year: year, month: month).call
      laundry_group_labels = scoped.sections.find { |s| s.key == :laundry }.groups.map(&:label)
      expect(laundry_group_labels).not_to include(laundry.name)
      expect(laundry_group_labels).to include(branch.name)
      expect(scoped.sections.find { |s| s.key == :laundry }.total).to eq(500)

      bp = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.totals
      expect(scoped.reconciliation.report_total).to eq(bp[:payroll] + bp[:inventory] + bp[:expenses])
      expect(scoped.reconciliation).to be_matches
    end
  end

  # Regression coverage for the July 2026 production discrepancy: Branch
  # Profitability totaled 349,551.30 while Expense Details totaled 399,876.03
  # — a 50,324.73 gap made of two distinct, now-fixed causes (see below).
  describe "July 2026 production discrepancy — non-sales branch leakage" do
    let(:non_sales_branch) { create(:branch, business: business, branch_type: "laundry") }
    let(:non_sales_employee) { create(:user, business: business) }

    before do
      # A non-sales branch (e.g. the physical laundry facility itself, not a
      # sales branch it launders towels for) can have its own real payroll,
      # inventory consumption, and direct expenses — BranchProfitability
      # intentionally never sums these (it only loops sales branches).
      period = PayrollPeriod.find_by!(business: business, period_year: year, period_month: month)
      create(:payroll_entry, payroll_period: period, user: non_sales_employee,
             base_salary: 2000, total_overtime: 0, total_bonuses: 0, net_salary: 2000)
      create(:shift_assignment, user: non_sales_employee, branch: non_sales_branch,
             effective_from: period_start - 1.month, effective_to: nil)

      business.inventory_movements.create!(product: product, warehouse: warehouse, branch: non_sales_branch,
        direction: "out", reason: "stock_issue", quantity: 5, unit_cost: 10, occurred_on: Date.current)

      create(:expense, :approved, business: business, branch: non_sales_branch, amount: 300, expense_date: Date.current)
    end

    it "excludes the non-sales branch's own payroll/inventory/direct-expense costs from every section total, matching Branch Profitability" do
      scoped = described_class.new(business, year: year, month: month).call

      # None of the non-sales branch's costs leak into any section total —
      # the totals must equal exactly what the sales-branch-only groups show.
      expect(scoped.sections.find { |s| s.key == :payroll }.total)
        .to eq(scoped.sections.find { |s| s.key == :payroll }.groups.sum(&:subtotal))
      expect(scoped.sections.find { |s| s.key == :inventory }.total)
        .to eq(scoped.sections.find { |s| s.key == :inventory }.groups.sum(&:subtotal))
      expect(scoped.sections.find { |s| s.key == :branch_expenses }.total)
        .to eq(scoped.sections.find { |s| s.key == :branch_expenses }.groups.sum(&:subtotal))

      bp = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.totals
      expect(scoped.reconciliation.report_total).to eq(bp[:payroll] + bp[:inventory] + bp[:expenses])
      expect(scoped.reconciliation).to be_matches
    end
  end

  # The second cause of the July 2026 discrepancy: real approved expenses
  # that predate/bypass Expense#normalize_branch_mode (branch_id nil AND
  # is_shared false) — structurally unattributable to any branch, so
  # BranchProfitability correctly can never include them. They must remain
  # fully visible (not hidden) but excluded from the reconciling total.
  describe "unattributed expenses (branch_id nil, is_shared false — no valid attribution path)" do
    let!(:orphan) do
      expense = build(:expense, business: business, branch: nil, amount: 45_260, expense_date: Date.current,
                       status: "approved")
      expense.is_shared = false
      expense.save!(validate: false)
      expense
    end

    it "is shown in its own 'other' section, but excluded from the reconciling total" do
      scoped = described_class.new(business, year: year, month: month).call
      other_section = scoped.sections.find { |s| s.key == :other }

      expect(other_section.total).to eq(45_260)
      expect(other_section.groups.flat_map(&:rows).map { |r| r[:reference] }).to include(orphan.reference_number)

      # Not part of RECONCILING_SECTION_KEYS — the report still matches
      # Branch Profitability exactly despite this real money existing.
      bp = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.totals
      expect(scoped.reconciliation.report_total).to eq(bp[:payroll] + bp[:inventory] + bp[:expenses])
      expect(scoped.reconciliation).to be_matches
      expect(scoped.reconciliation.report_total).not_to eq(scoped.sections.sum(&:total)) # grand total (incl. other) differs on purpose
    end

    it "does not appear when a specific branch is filtered (it has no branch to belong to)" do
      scoped = described_class.new(business, year: year, month: month, branch_id: branch.id).call
      expect(scoped.sections.find { |s| s.key == :other }.total).to eq(0)
    end
  end

  describe "empty period / no activity" do
    it "returns empty sections and a reconciling (zero) result for a business with no data" do
      quiet_business = create(:business)
      result = described_class.new(quiet_business, year: year, month: month).call

      expect(result.sections).to all(satisfy { |s| s.total.to_f.zero? })
      expect(result.reconciliation.report_total).to eq(0)
      expect(result.reconciliation).to be_matches
    end
  end

  # Multi-month range support (to_year:/to_month:). Each month gets its own
  # distinct PayrollPeriod/InventoryMovement/Expense records — the point is
  # to prove the range aggregates real per-month records (sum of 3 separate
  # months' data), not a single month's figure multiplied by 3.
  describe "multi-month range" do
    # Isolated business — avoids the outer `before` block's current-month
    # payroll fixture (shared `business`/`employee`) leaking into these
    # range totals; this describe's fixtures are the only data that exists.
    let(:business) { create(:business) }
    let(:month1) { 2.months.ago.to_date.beginning_of_month }
    let(:month2) { 1.month.ago.to_date.beginning_of_month }
    let(:month3) { Date.current.beginning_of_month }
    let(:range_branch) { create(:branch, business: business) }
    let(:range_employee) { create(:user, business: business) }

    def build_month(date, base_salary:, inventory_qty:, direct_amount:)
      period = PayrollPeriod.find_by(business: business, period_year: date.year, period_month: date.month) ||
        create(:payroll_period, business: business, period_year: date.year, period_month: date.month)
      create(:payroll_entry, payroll_period: period, user: range_employee,
             base_salary: base_salary, total_overtime: 0, total_bonuses: 0, net_salary: base_salary)
      create(:shift_assignment, user: range_employee, branch: range_branch,
             effective_from: date - 1.month, effective_to: nil) unless ShiftAssignment.exists?(user: range_employee, branch: range_branch)

      business.inventory_movements.create!(product: product, warehouse: warehouse, branch: range_branch,
        direction: "out", reason: "stock_issue", quantity: inventory_qty, unit_cost: 10, occurred_on: date)

      create(:expense, :approved, business: business, branch: range_branch, amount: direct_amount, expense_date: date)
    end

    before do
      build_month(month1, base_salary: 1000, inventory_qty: 2, direct_amount: 50)
      build_month(month2, base_salary: 1500, inventory_qty: 3, direct_amount: 75)
      build_month(month3, base_salary: 2000, inventory_qty: 4, direct_amount: 100)
    end

    subject(:ranged) do
      described_class.new(business, year: month1.year, month: month1.month,
                          to_year: month3.year, to_month: month3.month).call
    end

    def range_section(key) = ranged.sections.find { |s| s.key == key }

    # Scoped to range_branch's own group subtotal, not the whole-business
    # section total — the file's shared top-level `before` block also creates
    # an unrelated branch/employee for the current month (= month3 here) on
    # this same business, which legitimately belongs in the section's
    # business-wide total but would make these range-arithmetic assertions
    # about noise instead of the thing being tested.
    def range_branch_subtotal(key)
      range_section(key).groups.find { |g| g.branch_id == range_branch.id }&.subtotal.to_f
    end

    it "sums real per-month records across the range, not a single month multiplied out" do
      expect(range_branch_subtotal(:payroll)).to eq(1000 + 1500 + 2000)
      expect(range_branch_subtotal(:inventory)).to eq(20 + 30 + 40) # qty*unit_cost per month
      expect(range_branch_subtotal(:branch_expenses)).to eq(50 + 75 + 100)
    end

    it "shows one payroll row per employee per month (3 distinct entries, not one row)" do
      rows = range_section(:payroll).groups.find { |g| g.branch_id == range_branch.id }.rows
      expect(rows.size).to eq(3)
      expect(rows.map { |r| r[:gross] }.sort).to eq([ 1000, 1500, 2000 ])
    end

    it "reconciles against the SUM of Branch Profitability's totals for each month in range (not one month's total)" do
      expected = [ month1, month2, month3 ].sum do |date|
        bp = Finance::Reports::BranchProfitability.new(business, year: date.year, month: date.month).call.totals
        bp[:payroll] + bp[:inventory] + bp[:expenses]
      end

      expect(ranged.reconciliation.report_total).to eq(expected)
      expect(ranged.reconciliation).to be_matches
    end

    it "does not equal a single month's Branch Profitability total (proves it isn't comparing range vs one month)" do
      single_month_bp = Finance::Reports::BranchProfitability.new(business, year: month3.year, month: month3.month).call.totals
      single_month_total = single_month_bp[:payroll] + single_month_bp[:inventory] + single_month_bp[:expenses]

      expect(ranged.reconciliation.branch_profitability_total).not_to eq(single_month_total)
    end

    it "scopes correctly to a single branch across the whole range" do
      scoped = described_class.new(business, year: month1.year, month: month1.month,
                                   to_year: month3.year, to_month: month3.month, branch_id: range_branch.id).call

      expect(scoped.sections.find { |s| s.key == :payroll }.total).to eq(1000 + 1500 + 2000)
      expect(scoped.reconciliation).to be_matches
    end

    it "backward-compatible default (no to_year/to_month) still resolves to a single month" do
      single = described_class.new(business, year: month3.year, month: month3.month).call
      subtotal = single.sections.find { |s| s.key == :payroll }.groups.find { |g| g.branch_id == range_branch.id }&.subtotal
      expect(subtotal).to eq(2000)
    end
  end
end
