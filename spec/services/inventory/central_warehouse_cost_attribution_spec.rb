require "rails_helper"

# Decision 1 (owner, 2026-11-24): Stock Issues from a branch warehouse are
# attributed to that branch; Stock Issues from a CENTRAL warehouse stay
# Unallocated — never attributed to a branch automatically — and are still
# counted in every company-level total. Historical branch attribution is kept
# exactly as recorded (no redistribution).
#
#   Nasr WH (branch warehouse of Nasr) : 3 × 10 = 30  → Nasr
#   Central                            : 5 × 10 = 50  → Unallocated
#   historical issue from Central, recorded for Maadi: 2 × 10 = 20 → Maadi (unchanged)
RSpec.describe "Central warehouse consumption stays Unallocated" do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:nasr)    { create(:branch, business: business, name: "Nasr", branch_type: "sales") }
  let!(:maadi)   { create(:branch, business: business, name: "Maadi", branch_type: "sales") }
  let!(:nasr_wh) { branch_warehouse_for(nasr, name: "Nasr WH") }
  let!(:central) { business.warehouses.create!(name: "Central", kind: "central") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }
  let(:year)  { Date.current.year }
  let(:month) { Date.current.month }
  let(:unallocated_label) { I18n.t("finance.reports.unallocated") }

  def receive!(warehouse, quantity)
    receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    receipt.items.build(product: product, quantity: quantity, unit_cost: 10)
    expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
  end

  # Through the real workflow (the owner may approve their own issue).
  def issue!(warehouse, quantity)
    issue = business.stock_issues.build(warehouse: warehouse, issued_on: Date.current, created_by: owner)
    issue.items.build(product: product, quantity: quantity)
    expect(Inventory::StockIssueDraftService.new(issue, actor: owner).call).to be_ok
    expect(Inventory::StockIssueSubmission.new(stock_issue_id: issue.id, actor: owner).call).to be_ok
    expect(Inventory::StockIssueApproval.new(stock_issue_id: issue.id, actor: owner).approve!).to be_ok
    expect(Inventory::StockIssueConfirmationService.new(stock_issue_id: issue.id, actor: owner).call).to be_ok
    issue.reload
  end

  let!(:historical) do
    receive!(central, 100)
    receive!(nasr_wh, 100)
    # Recorded under the earlier rule: central warehouse, consuming branch Maadi.
    old = business.stock_issues.build(warehouse: central, branch: maadi, issued_on: Date.current, created_by: owner,
                                      warehouse_source: "selected")
    old.items.build(product: product, quantity: 2)
    approve_and_post_stock_issue(old)
    old.reload
  end
  let!(:branch_issue)  { issue!(nasr_wh, 3) }
  let!(:central_issue) { issue!(central, 5) }

  it "records the attribution on the issue and its movements" do
    expect(branch_issue.branch_id).to eq(nasr.id)
    expect(central_issue.branch_id).to be_nil
    expect(central_issue.inventory_movements.pluck(:branch_id)).to eq([ nil ])
    expect(historical.reload.branch_id).to eq(maadi.id)
    expect(historical.inventory_movements.pluck(:branch_id)).to eq([ maadi.id ])
  end

  it "keeps ConsumptionLedger's attribution: branch, Unallocated (nil) and the historical branch" do
    costs = Inventory::ConsumptionLedger.new(business).cost_by_branch
    expect(costs.transform_values(&:to_d)).to eq(nasr.id => 30, maadi.id => 20, nil => 50)
  end

  describe Finance::Reports::BranchProfitability do
    let(:table) { described_class.new(business, year: year, month: month).call }

    it "shows central consumption on the Unallocated line only, and counts it once in the total" do
      rows = table.rows.index_by { |r| r[:branch] }
      expect(rows["Nasr"][:inventory].to_d).to eq(30)
      expect(rows["Maadi"][:inventory].to_d).to eq(20)
      expect(table.unallocated).to include(branch: unallocated_label)
      expect(table.unallocated[:inventory].to_d).to eq(50)
      expect(table.totals[:inventory].to_d).to eq(100)
    end
  end

  describe Finance::Reports::ExpenseDetails do
    it "lists central consumption in an Unallocated group, reconciling with Branch Profitability" do
      report  = described_class.new(business, year: year, month: month).call
      section = report.sections.find { |s| s.key == :inventory }
      groups  = section.groups.index_by(&:label)

      expect(groups.fetch(unallocated_label).subtotal.to_d).to eq(50)
      expect(section.total.to_d).to eq(100)
      expect(report.reconciliation.report_total).to eq(report.reconciliation.branch_profitability_total)
    end

    it "leaves the Unallocated group out under a branch filter" do
      report  = described_class.new(business, year: year, month: month, branch_id: nasr.id).call
      section = report.sections.find { |s| s.key == :inventory }
      expect(section.groups.map(&:label)).to eq([ "Nasr" ])
      expect(section.total.to_d).to eq(30)
    end
  end

  describe Inventory::Reports::Consumption do
    it "keeps a no-branch row (shown as Unallocated) and includes it in the totals" do
      report = described_class.new(business)
      by_branch = report.rows.to_h { |r| [ r.branch&.name, r.net_value.to_d ] }
      expect(by_branch).to eq("Nasr" => 30, "Maadi" => 20, nil => 50)
      expect(report.total_value.to_d).to eq(100)
      expect(described_class.new(business, branch_id: nasr.id).rows.map { |r| r.branch.name }).to eq([ "Nasr" ])
    end
  end

  describe Inventory::Reports::BranchComparison do
    let(:report) { described_class.new(business, product_id: product.id) }

    it "shows central consumption as its own Unallocated row — never ranked as a branch — within the total" do
      expect(report.branch_rows.map { |r| r.branch.name }).to contain_exactly("Nasr", "Maadi")
      expect(report.unallocated_row.net_consumption.to_d).to eq(5)
      expect(report.total_consumption.to_d).to eq(10)
      expect(report.highest_branch.branch.name).to eq("Nasr")
      expect((report.branch_rows.sum(&:share) + report.unallocated_row.share).round(6)).to eq(100)
    end

    it "omits the Unallocated row under a branch filter" do
      filtered = described_class.new(business, product_id: product.id, branch_id: nasr.id)
      expect(filtered.unallocated_row).to be_nil
      expect(filtered.total_consumption.to_d).to eq(3)
    end

    it "exports the Unallocated row once" do
      csv = Inventory::Reports::BranchComparisonExport.new(report).to_csv
      expect(csv.scan(I18n.t("inventory.reports.unallocated")).size).to eq(1)
    end
  end

  describe Inventory::Reports::Movements do
    it "never counts central consumption under a branch filter, but lists it unfiltered" do
      issued = ->(**filters) { described_class.new(business, reason: "stock_issue", **filters).rows.map { |r| r.warehouse.id } }
      expect(issued.call).to include(central.id)
      expect(issued.call(branch_id: nasr.id)).to eq([ nasr_wh.id ])
    end
  end

  it "keeps the void of a central issue Unallocated (nets to zero there), reversing into Central" do
    expect(Inventory::DocumentVoider.new(central_issue, user: owner, reason: "wrong").call).to be_ok
    costs = Inventory::ConsumptionLedger.new(business).cost_by_branch.transform_values(&:to_d)
    expect(costs[nil]).to eq(0)
    expect(costs[nasr.id]).to eq(30)
    expect(InventoryMovement.where(source: central_issue, direction: "in").pluck(:warehouse_id)).to eq([ central.id ])
  end
end
