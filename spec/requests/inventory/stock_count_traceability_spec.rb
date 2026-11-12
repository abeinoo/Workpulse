require "rails_helper"

# Decision D5: every movement a stock count posts — and its reversal — is
# traceable to the count's SC number, everywhere movements are listed, and a
# manual adjustment can never pose as a stock count.
RSpec.describe "Stock count movement traceability", type: :request do
  let(:business)  { create(:business) }
  let(:owner)     { create(:user, :owner, business: business) }
  let(:counter)   { user_with_stock_permissions(business, :view_inventory, :manage_stock_counts) }
  let(:approver)  { user_with_stock_permissions(business, :view_inventory, :post_stock_counts) }
  let(:warehouse) { business.warehouses.create!(name: "Main") }
  let(:product)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 4, average_cost_price: 4) }

  let!(:count) do
    r = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
    r.items.build(product: product, quantity: 4, unit_cost: 4)
    Inventory::GoodsReceiptPoster.new(r).call
    c = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [ [ product, 3 ] ], complete: true)
    expect(approve_stock_count(c, approver).ok?).to be(true)
    c.reload
  end
  let(:adjustment) { count.stock_adjustments.first }

  def report(**filters) = Inventory::Reports::Movements.new(business, **filters)
  def count_rows(**filters) = report(**filters).rows.select(&:stock_count)

  it "identifies the stock count on its movement rows" do
    row = count_rows.sole
    expect(row.stock_count).to eq(count)
    expect([ row.reason, row.direction, row.quantity, row.product, row.warehouse ])
      .to eq([ "adjustment", "out", 1, product, warehouse ])
    expect(row.document_number).to eq(adjustment.adjustment_number)
  end

  it "finds the movements by the SC number as well as by the ADJ number" do
    expect(report(document_number: count.count_number).rows.map(&:stock_count)).to eq([ count ])
    expect(report(document_number: adjustment.adjustment_number).rows.size).to eq(1)
  end

  it "keeps the stock count reference on reversal movements" do
    reopen_stock_count(count, approver, reason: "recount")
    rows = count_rows
    expect(rows.map(&:reason)).to contain_exactly("adjustment", "reversal")
    expect(rows.map(&:stock_count).uniq).to eq([ count ])
    expect(report(document_number: count.count_number, reason: "reversal").rows.sole.direction).to eq("in")
  end

  it "shows SC-xxxx, linked to the count, as a Stock Count movement in the report, dashboard and product page" do
    reopen_stock_count(count, approver, reason: "recount")
    sign_in owner

    get inventory_movements_report_path
    expect(response.body).to include(count.count_number, inventory_stock_count_path(count))
    expect(response.body).to include(I18n.t("inventory.movements.stock_count_reasons.adjustment"),
                                     I18n.t("inventory.movements.stock_count_reasons.reversal"))

    get inventory_root_path
    expect(response.body).to include(count.count_number, I18n.t("inventory.dashboard.overview.kinds.stock_count"),
                                     I18n.t("inventory.dashboard.overview.kinds.stock_count_reversal"))

    get inventory_product_path(product)
    expect(response.body).to include(count.count_number, inventory_stock_count_path(count))
  end

  it "exports the stock count reference and type" do
    sign_in owner
    get inventory_movements_report_export_path(format: :csv)
    line = response.body.lines.find { |l| l.include?(count.count_number) }
    expect(line).to include("#{count.count_number} / #{adjustment.adjustment_number}")
    expect(line).to include(I18n.t("inventory.reports.source_types.StockCount"),
                            I18n.t("inventory.movements.stock_count_reasons.adjustment"))
  end

  it "does not classify manual adjustments as stock counts" do
    manual = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: "damaged", created_by: owner)
    manual.items.build(product: product, quantity_difference: -1)
    expect(Inventory::AdjustmentPoster.new(manual).call.ok?).to be(true)
    expect(report(document_number: manual.adjustment_number).rows.sole.stock_count).to be_nil

    posing = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: "stock_count")
    posing.items.build(product: product, quantity_difference: 1)
    expect(Inventory::AdjustmentPoster.new(posing).call.ok?).to be(false)
    expect(posing.errors[:reason]).to be_present
  end

  it "offers no stock-count reason on the manual adjustment form, and defaults to a manual correction" do
    sign_in owner
    get new_inventory_stock_adjustment_path
    form = Nokogiri::HTML(response.body)
    options = form.css("select[name='stock_adjustment[reason]'] option").map { |o| o["value"] }
    expect(options).not_to include("stock_count")
    expect(form.at_css("select[name='stock_adjustment[reason]'] option[selected]")["value"]).to eq("manual_correction")
  end

  it "leaves branch consumption figures untouched" do
    expect(Inventory::ConsumptionLedger.new(business).net_quantity).to eq(0)
  end
end
