require "rails_helper"

# Characterization (Pilot 11 — Reporting: laundry labour-cost report, M1) —
# CURRENT behaviour of Laundry::LaundryCostSummaryReport that the M4 relocation
# must keep (next-pilot-selection.md §26.6, gaps G1, G3, G6). Pinned against the
# unchanged code at 96cfc31; known debt is labelled as current behaviour.
#
# Already pinned elsewhere, not repeated: the component formulas, status / date /
# business filters (spec/services/laundry/laundry_cost_summary_report_spec.rb),
# the branch-count states, include_payroll: false and cross-business isolation
# (…/laundry_cost_summary_report_guards_spec.rb), the HTML / CSV visibility rules
# (spec/requests/laundry/cost_summary_visibility_spec.rb).
RSpec.describe Finance::Reports::LaundryCostSummary, type: :model do
  let(:business)        { create(:business) }
  let!(:sales_branch)   { create(:branch, business: business, branch_type: "sales") }
  let!(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
  let(:actor)           { create(:user, business: business) }
  let(:towel_type)      { business.towel_types.create!(name: "Bath Towel") }

  let(:from) { Date.current.beginning_of_month }
  let(:to)   { Date.current.end_of_month }

  before { business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 1.5, effective_from: 1.year.ago) }

  def run(**options)
    described_class.new(business, from: from, to: to, **options).call
  end

  def receive_towels!(destination:, confirmed:)
    Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: sales_branch, status: "clean",
                                                   adjustment_quantity: confirmed + 10, reason: "test setup")
    transfer = Laundry::TowelTransferCreator.create(actor: actor, params: {
      source_branch_id: sales_branch.id, destination_branch_id: destination.id, towel_status: "dirty",
      items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: confirmed } ]
    }).transfer
    Laundry::TowelTransferCreator.new(transfer).dispatch(actor: actor)
    Laundry::TowelTransferCreator.new(transfer.reload)
                                 .receive(actor: actor, confirmed_quantities: { transfer.items.first.id => confirmed })
    transfer.reload
  end

  describe "G1 — standard cost counts only receipts at the selected laundry branch" do
    it "excludes towels received at a laundry branch that was later deactivated" do
      old_laundry = create(:branch, business: business, branch_type: "laundry")
      old_transfer = receive_towels!(destination: old_laundry, confirmed: 40)
      old_laundry.update_column(:active, false)
      current_transfer = receive_towels!(destination: laundry_branch, confirmed: 100)
      expect([ old_transfer, current_transfer ].map(&:status)).to all(eq("received"))

      result = run

      expect(result.laundry_branch).to eq(laundry_branch)
      expect(result.standard_towels).to eq(100)
      expect(result.standard_cost).to eq(150)
      expect(result.coverage_variance).to eq(150 - result.actual_operating_cost)
      expect(result.actual_cost_per_towel).to eq(result.actual_operating_cost / 100)
      # Current behaviour (TD-P11-6): Result#consumption is still the business-wide
      # consumption report, including the old branch's receipt.
      expect(result.consumption.total_towels).to eq(140)
      expect(result.consumption.total_cost).to eq(210)
    end
  end

  describe "G3 — payroll attribution (TD-P11-3, current behaviour: no proration)" do
    let!(:period) do
      create(:payroll_period, :finalized, business: business, branch: nil,
                                          period_year: Date.current.year, period_month: Date.current.month)
    end
    let(:from) { period.period_start }
    let(:to)   { period.period_end }

    def employee_with_assignment(effective_from:, effective_to:, net_salary:)
      create(:user, business: business).tap do |user|
        create(:shift_assignment, business: business, user: user, branch: laundry_branch,
                                  effective_from: effective_from, effective_to: effective_to)
        create(:payroll_entry, payroll_period: period, user: user, net_salary: net_salary)
      end
    end

    it "counts the whole net_salary for a laundry assignment covering only part of the period" do
      employee_with_assignment(effective_from: period.period_start + 10, effective_to: period.period_start + 12,
                               net_salary: 3000)

      expect(run.payroll_cost).to eq(3000)
    end

    it "counts the whole net_salary when the assignment only touches the period's last day" do
      employee_with_assignment(effective_from: period.period_end, effective_to: nil, net_salary: 2500)

      expect(run.payroll_cost).to eq(2500)
    end

    it "excludes an assignment that ended the day before the period started" do
      employee_with_assignment(effective_from: period.period_start - 20, effective_to: period.period_start - 1,
                               net_salary: 4000)

      expect(run.payroll_cost).to eq(0)
    end

    it "counts the whole net_salary of an employee who also worked at a sales branch in the period" do
      user = employee_with_assignment(effective_from: period.period_start, effective_to: period.period_start + 2,
                                      net_salary: 5000)
      create(:shift_assignment, business: business, user: user, branch: sales_branch,
                                effective_from: period.period_start + 3, effective_to: nil)

      expect(run.payroll_cost).to eq(5000)
    end
  end

  describe "G6 — a run writes nothing" do
    def sql_writes(&block)
      writes = []
      recorder = lambda do |*, payload|
        sql = payload[:sql].to_s
        writes << sql if sql.match?(/\A\s*(?:INSERT|UPDATE|DELETE|MERGE|TRUNCATE)\b/i)
      end
      ActiveSupport::Notifications.subscribed(recorder, "sql.active_record", &block)
      writes
    end

    let(:warehouse) { business.warehouses.create!(name: "Laundry Warehouse") }
    let(:product) do
      business.products.create!(name: "Detergent", sku: "DET-1", unit_of_measure: "kg",
                                initial_cost_price: 20, average_cost_price: 20)
    end

    before do
      receive_towels!(destination: laundry_branch, confirmed: 30)

      user = create(:user, business: business)
      create(:shift_assignment, business: business, user: user, branch: laundry_branch,
                                effective_from: from - 1.month, effective_to: nil)
      period = create(:payroll_period, :finalized, business: business, branch: nil,
                                                   period_year: from.year, period_month: from.month)
      create(:payroll_entry, payroll_period: period, user: user, net_salary: 1000)

      create(:expense, :approved, business: business, branch: laundry_branch,
                                  expense_category: create(:expense_category, business: business),
                                  amount: 50, expense_date: from + 2.days)

      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: from + 1.day)
      receipt.items.build(product: product, quantity: 10, unit_cost: 20)
      Inventory::GoodsReceiptPoster.new(receipt).call
      issue = business.stock_issues.build(warehouse: warehouse, branch: laundry_branch, issued_on: from + 2.days)
      issue.items.build(product: product, quantity: 2)
      approve_and_post_stock_issue(issue)
    end

    def snapshot
      [ PayrollEntry, PayrollPeriod, StockIssue, StockIssueItem, InventoryMovement, TowelTransfer,
        TowelTransferItem, TowelLedgerEntry, Expense, ExpenseAllocation ].to_h do |model|
        [ model.name, model.order(:id).pluck(:id, :updated_at) ]
      end
    end

    it "detects a write (control for the recorder below)" do
      expect(sql_writes { laundry_branch.update_column(:name, "Renamed") }).not_to be_empty
    end

    it "issues no INSERT / UPDATE / DELETE with payroll included" do
      result = nil
      expect(sql_writes { result = run }).to be_empty
      expect([ result.payroll_cost, result.direct_expenses, result.material_cost, result.standard_cost ])
        .to eq([ 1000, 50, 40, 45 ])
    end

    it "issues no INSERT / UPDATE / DELETE with payroll withheld" do
      expect(sql_writes { run(include_payroll: false) }).to be_empty
    end

    it "leaves payroll entries, stock issues, towel transfers and expenses unchanged" do
      before_run = snapshot
      run
      run(include_payroll: false)

      expect(snapshot).to eq(before_run)
      # Not vacuous: the records the report reads exist.
      expect(before_run.slice("PayrollEntry", "StockIssue", "TowelTransfer", "Expense").values).to all(be_present)
    end
  end
end
