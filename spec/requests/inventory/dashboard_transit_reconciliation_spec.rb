require "rails_helper"

# The dashboard's per-warehouse summary reconciles with the business total
# (Current stock value) at every stage of a transfer: goods in transit are
# their own "In Transit" row for a viewer of every warehouse — never an
# operational warehouse row, link or choice — and the rows plus that row
# always add up to the total, with the same valuation.
RSpec.describe "Dashboard inventory reconciliation with stock in transit", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:main)    { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:annex)   { business.warehouses.create!(name: "Annex") }
  let!(:product) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 10, average_cost_price: 10) }

  before do
    InventoryMovement.create!(business: business, product: product, warehouse: main, direction: :in, reason: :opening_balance,
                              quantity: 100, unit_cost: 10, occurred_on: Date.new(2026, 1, 1))
  end

  def summary
    Inventory::Reports::WarehouseSummary.new(business, warehouses: business.warehouses.operational.to_a,
                                                       movement_summary: instance_double(Inventory::Reports::MovementSummary, counts_by_warehouse: {}),
                                                       low_stock_alerts: [], transit_warehouse: Inventory::TransitWarehouse.find_for(business))
  end

  def business_total = Inventory::Reports::Overview.new(business, warehouse_ids: nil).total_value

  def expect_reconciled(transit_value)
    s = summary
    expect(s.total_value).to eq(business_total)
    expect(s.transit_row&.stock_value || 0).to eq(transit_value)
    expect(s.rows.map(&:warehouse)).to contain_exactly(main, annex) # never an operational row
  end

  def svc(klass, transfer, **args)
    klass.new(stock_transfer_id: transfer.id, actor: owner, **args).call.tap { |r| raise r.error.to_s unless r.ok? }
  end

  def transfer(qty)
    t = Inventory::StockTransferDraftService.new(actor: owner, attributes: {
      source_warehouse_id: main.id, destination_warehouse_id: annex.id, items_attributes: { "0" => { product_id: product.id, quantity: qty } }
    }).call.transfer
    svc(Inventory::StockTransferSubmission, t)
    svc(Inventory::StockTransferApproval, t)
    t.reload
  end

  it "reconciles before dispatch, in transit, after partial and full receipts, after a return and a write-off" do
    t = transfer(30)
    expect_reconciled(0) # approved: reserved, nothing moved, no transit row yet
    expect(summary.transit_row).to be_nil

    svc(Inventory::StockTransferDispatch, t)
    expect_reconciled(300) # 30 × 10 in transit
    item = t.items.first

    svc(Inventory::StockTransferReceiving, t.reload, quantities: { item.id => 10 })
    expect_reconciled(200)

    svc(Inventory::StockTransferReceiving, t.reload, quantities: { item.id => 12 }, close_shortfall: true)
    expect_reconciled(80)

    svc(Inventory::StockTransferDiscrepancyResolution, t.reload, entries: { item.id => { "return_to_source" => 5 } }, reason: "back")
    expect_reconciled(30)

    svc(Inventory::StockTransferDiscrepancyResolution, t.reload, entries: { item.id => { "write_off" => 3 } }, reason: "lost")
    expect_reconciled(0) # the written-off value left the business total too
    expect(business_total).to eq(970)

    full = transfer(10)
    svc(Inventory::StockTransferDispatch, full)
    svc(Inventory::StockTransferReceiving, full.reload, quantities: { full.items.first.id => 10 })
    expect_reconciled(0)
  end

  describe "the dashboard" do
    before do
      t = transfer(30)
      svc(Inventory::StockTransferDispatch, t)
    end

    it "shows the In Transit row — not a link, not a warehouse — and a total equal to the business total" do
      sign_in owner
      get inventory_root_path
      doc = Nokogiri::HTML(response.body)
      row = doc.at_css("[data-testid='warehouse-summary-transit']")
      expect(row.text).to include(I18n.t("inventory.transit_warehouse.name"))
      expect(row.css("a")).to be_empty
      expect(response.body).not_to include(Warehouse::TRANSIT_NAME)
      total = doc.at_css("[data-testid='warehouse-summary-total']").text
      expect(total).to include("1,000") # 100 units × 10 = the business total, transit included
    end

    it "labels it «بالطريق» in Arabic" do
      owner.update_column(:preferred_locale, "ar")
      sign_in owner
      get inventory_root_path
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='warehouse-summary-transit']").text).to include("بالطريق")
    end

    it "never shows it to a viewer limited to some warehouses (their total excludes it too)" do
      scoped = user_with_stock_permissions(business, :view_inventory)
      WarehouseAssignment.create!(user: scoped, warehouse: main)
      WarehouseAssignment.create!(user: scoped, warehouse: annex)
      sign_in scoped
      get inventory_root_path
      expect(Nokogiri::HTML(response.body).at_css("[data-testid='warehouse-summary-transit']")).to be_nil
    end
  end
end
