require "rails_helper"

RSpec.describe Finance::Reports::ExpenseSources, type: :model do
  let(:business)  { create(:business) }
  let(:branch)    { create(:branch, business: business) }
  let(:other)     { create(:branch, business: business) }
  let(:category)  { create(:expense_category, business: business) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Dye", sku: "DYE-1", initial_cost_price: 0, average_cost_price: 0) }
  let(:year)  { Date.current.year }
  let(:month) { Date.current.month }
  let(:employee) { create(:user, business: business) }
  let(:period_start) { Date.new(year, month, 1) }

  subject(:sources) { described_class.new(business, year: year, month: month) }

  before do
    period = create(:payroll_period, business: business, period_year: year, period_month: month)
    create(:payroll_entry, payroll_period: period, user: employee, base_salary: 5000, total_overtime: 300, total_bonuses: 200, net_salary: 5500)
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

  describe "coarse figures — identical to BranchProfitability's original inline queries" do
    it "computes payroll gross by branch" do
      expect(sources.payroll_costs[branch.id]).to eq(5500)
    end

    it "computes inventory consumption only (excludes purchases)" do
      expect(sources.inventory_costs[branch.id]).to eq(120)
    end

    it "computes direct expenses by branch" do
      expect(sources.direct_expenses[branch.id]).to eq(1000)
    end

    it "computes allocated expenses by branch" do
      expect(sources.allocated_expenses[branch.id]).to eq(100)
      expect(sources.allocated_expenses[other.id]).to eq(100)
    end

    it "reconciles exactly with BranchProfitability's totals for the same fixtures" do
      bp_row = Finance::Reports::BranchProfitability.new(business, year: year, month: month).call.rows
        .find { |r| r[:branch] == branch.name }

      expect(sources.payroll_costs[branch.id]).to eq(bp_row[:payroll])
      expect(sources.inventory_costs[branch.id]).to eq(bp_row[:inventory])
      expect(sources.direct_expenses[branch.id] + sources.allocated_expenses[branch.id]).to eq(bp_row[:expenses])
    end
  end

  describe "detail methods" do
    it "returns payroll entries grouped by the same branch attribution as payroll_costs" do
      entries = sources.payroll_entries_by_branch[branch.id]
      expect(entries.map(&:user_id)).to eq([ employee.id ])
    end

    it "returns inventory movements grouped by branch and product, summing to inventory_costs" do
      rows = sources.inventory_movements_by_branch_product[branch.id]
      expect(rows.size).to eq(1)
      expect(rows.first[:product]).to eq(product)
      expect(rows.first[:quantity]).to eq(10)
      expect(rows.first[:total]).to eq(120)
      expect(rows.sum { |r| r[:total] }).to eq(sources.inventory_costs[branch.id])
    end

    it "returns the direct expense records behind direct_expenses" do
      records = sources.direct_expense_records_by_branch[branch.id]
      expect(records.map(&:amount)).to eq([ 1000 ])
      expect(records.sum(&:amount)).to eq(sources.direct_expenses[branch.id])
    end

    it "returns the allocation records behind allocated_expenses" do
      records = sources.allocated_expense_records_by_branch[branch.id]
      expect(records.sum(&:allocated_amount)).to eq(sources.allocated_expenses[branch.id])
    end
  end

  describe "laundry cost" do
    let(:laundry_branch) { create(:branch, business: business, branch_type: "laundry") }
    let(:towel_type) { business.towel_types.create!(name: "Bath Towel") }
    let(:actor) { create(:user, business: business) }

    before do
      business.laundry_standard_cost_rates.create!(towel_type: towel_type, cost_per_towel: 5, effective_from: 1.year.ago)
      Laundry::TowelAdjuster.new(actor: actor).call(towel_type: towel_type, branch: branch, status: "clean",
                                                     adjustment_quantity: 100, reason: "test setup")
      created = Laundry::TowelTransferCreator.create(actor: actor, params: {
        source_branch_id: branch.id, destination_branch_id: laundry_branch.id, towel_status: "dirty",
        items_attributes: [ { towel_type_id: towel_type.id, declared_quantity: 100 } ]
      })
      transfer = created.transfer
      Laundry::TowelTransferCreator.new(transfer.reload).dispatch(actor: actor)
      item_id = transfer.reload.items.first.id
      Laundry::TowelTransferCreator.new(transfer).receive(actor: actor, confirmed_quantities: { item_id => 100 })
    end

    it "computes laundry cost by the sales branch that sent the towels" do
      expect(sources.laundry_costs[branch.id]).to eq(500)
    end

    it "returns the underlying towel events behind laundry_costs" do
      events = sources.laundry_events_by_branch[branch.id]
      expect(events.sum { |e| e.line_total }).to eq(sources.laundry_costs[branch.id])
    end
  end
end
