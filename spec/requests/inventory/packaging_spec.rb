require "rails_helper"

# Multi-unit screens (docs/inventory/multi_unit_nested_packaging_design.md §4, §7, §12): packaging
# configuration, the unit on document lines, purchase remaining in the
# purchase unit, the product's packaging on hand, unit-cost display and
# fixed-point CSV (BUG-072). EN + AR.
RSpec.describe "Multi-unit inventory screens", type: :request do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:main)     { business.warehouses.create!(name: "Main", kind: "central") }
  let!(:annex)    { business.warehouses.create!(name: "Annex") }
  let(:razor) do
    product = business.products.create!(name: "Razor", sku: "RZ-1", initial_cost_price: 0, average_cost_price: 0, unit_of_measure: "pieces")
    configure_packaging!(product, owner, [ "box", 10 ], [ "carton", 12 ])
  end

  def doc = Nokogiri::HTML(response.body)

  before { sign_in owner }

  describe "packaging configuration" do
    let(:plain) { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 0, average_cost_price: 0, unit_of_measure: "ml") }

    it "edits the chain innermost first, saves it, and shows it on the product page" do
      get packaging_inventory_product_path(plain)
      expect(response).to have_http_status(:ok)
      expect(doc.at_css("[data-testid='packaging-levels']")).to be_present

      patch packaging_inventory_product_path(plain), params: { packaging: { levels: {
        "0" => { package_unit: "bottle", contains_quantity: "355" }, "1" => { package_unit: "case", contains_quantity: "12" } } } }
      expect(response).to redirect_to(inventory_product_path(plain))
      expect(plain.reload.active_packaging_levels.map { |l| [ l.package_unit, l.base_quantity.to_i ] }).to eq([ [ "bottle", 355 ], [ "case", 4260 ] ])
      expect(plain.measure_amount).to eq(355)

      get inventory_product_path(plain)
      chain = doc.at_css("[data-testid='packaging-chain']").text.squish
      expect(chain).to include("1 case = 12 bottles", "(4260 ml)", "1 bottle = 355 ml")
    end

    it "refuses a fifth level with a clear message and keeps the product unchanged" do
      levels = %w[box carton case pallet pack].each_with_index.to_h { |unit, i| [ i.to_s, { package_unit: unit, contains_quantity: "2" } ] }
      patch packaging_inventory_product_path(plain), params: { packaging: { levels: levels } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("at most 4 packaging levels")
      expect(plain.packaging_levels).to be_empty
    end

    it "only product editors may change packaging (configure_packaging?); viewers are refused and nothing changes" do
      viewer = user_with_stock_permissions(business, :view_inventory)
      sign_in viewer
      get packaging_inventory_product_path(plain)
      expect(response).not_to have_http_status(:ok)
      patch packaging_inventory_product_path(plain), params: { packaging: { levels: { "0" => { package_unit: "bottle", contains_quantity: "355" } } } }
      expect(plain.reload.packaging_levels).to be_empty
      get inventory_product_path(plain)
      expect(doc.at_css("[data-testid='edit-packaging']")).to be_nil
    end

    it "is translated in Arabic (right-to-left)" do
      owner.update!(preferred_locale: "ar")
      get packaging_inventory_product_path(razor)
      expect(response.body).to include('dir="rtl"', "التعبئة", "كرتونة")
      expect(response.body).not_to include("translation missing")
    end

    it "locks the Measure on the product form once stock has moved, and the Amount while packaging defines it" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ] ])
      get edit_inventory_product_path(razor)
      expect(doc.at_css("select[name='product[unit_of_measure]']")["disabled"]).to be_present
      expect(doc.at_css("input[name='product[measure_amount]']")["disabled"]).to be_present
      expect(doc.at_css("[data-testid='base-unit-locked']")).to be_present
    end
  end

  describe "document lines" do
    it "a transfer entered in boxes is posted in base units and shown as '5 boxes (50 pcs)'" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 3, 120 ] ])
      post inventory_stock_transfers_path, params: { stock_transfer: {
        source_warehouse_id: main.id, destination_warehouse_id: annex.id, transferred_on: Date.current.to_s,
        items_attributes: { "0" => { product_id: razor.id, entered_quantity: "5", packaging_level_id: level_of(razor, "box").id } } } }
      transfer = business.stock_transfers.last
      expect(response).to redirect_to(inventory_stock_transfer_path(transfer))
      expect(transfer.items.sole.quantity).to eq(50)
      expect(packaging_state(razor, annex)).to eq("carton" => 0, "box" => 5, loose: 0, total: 50)

      get inventory_stock_transfer_path(transfer)
      expect(doc.at_css("[data-testid='line-quantity']").text.squish).to eq("5 boxes (50 pcs)")
    end

    it "offers the product's units on the line (base unit + levels) and in the product picker payload" do
      razor
      get new_inventory_stock_transfer_path
      expect(response).to have_http_status(:ok)
      get inventory_product_search_path(q: "RZ-1"), as: :json
      units = response.parsed_body.first["units"]
      expect(units.map { |u| [ u["unit"], u["base"] ] }).to eq([ [ nil, "1" ], [ "box", "10" ], [ "carton", "120" ] ])
    end

    it "an approved issue previews what posting will do to the sealed packages; the posted transfer shows its effect" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ] ])
      issue = business.stock_issues.build(warehouse: main, branch: create(:branch, business: business), issued_on: Date.current)
      issue.items.build(product: razor, entered_quantity: 3, packaging_level: level_of(razor, "box"))
      save_stock_issue_in_status!(issue, :approved)
      get inventory_stock_issue_path(issue)
      expect(doc.at_css("[data-testid='packaging-preview']").text.squish)
        .to eq("Packaging at posting: opens 1 carton · takes 3 boxes sealed")

      post inventory_stock_transfers_path, params: { stock_transfer: {
        source_warehouse_id: main.id, destination_warehouse_id: annex.id, transferred_on: Date.current.to_s,
        items_attributes: { "0" => { product_id: razor.id, entered_quantity: "90", packaging_level_id: "" } } } } # 30 stay for the reservation
      get inventory_stock_transfer_path(business.stock_transfers.last)
      effects = doc.css("[data-testid='packaging-effects'] tbody tr").map { |tr| tr.css("td").map { |td| td.text.squish }.join(" ") }
      expect(effects).to eq([ "Main Razor opens 1 carton · opens 9 boxes" ])
    end

    it "a strict package shortfall at posting explains what is on hand" do
      receive_units!(product: razor, warehouse: main, lines: [ [ nil, 25, 1 ] ])
      post inventory_stock_transfers_path, params: { stock_transfer: {
        source_warehouse_id: main.id, destination_warehouse_id: annex.id, transferred_on: Date.current.to_s,
        items_attributes: { "0" => { product_id: razor.id, entered_quantity: "1", packaging_level_id: level_of(razor, "box").id } } } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(CGI.unescapeHTML(response.body)).to include("needs 1 box as full packages", "25 pcs")
    end
  end

  describe "purchasing in packages" do
    let(:request) do
      pr = business.purchase_requests.create!(warehouse: main, created_by: owner,
                                              items_attributes: [ { product_id: razor.id, entered_quantity: 2,
                                                                    packaging_level_id: level_of(razor, "carton").id, entered_unit_price: 120 } ])
      pr.update_columns(status: "pending_approval", submitted_by_id: owner.id)
      Inventory::PurchaseRequestApproval.new(purchase_request_id: pr.id, actor: owner).approve!
      pr.reload
    end

    it "the purchase request form creates a line in cartons, priced per carton, stored in base units" do
      post inventory_purchase_requests_path, params: { idempotency_key: SecureRandom.uuid, purchase_request: {
        warehouse_id: main.id,
        items_attributes: { "0" => { product_id: razor.id, entered_quantity: "2", packaging_level_id: level_of(razor, "carton").id,
                                     entered_unit_price: "120" } } } }
      line = business.purchase_requests.last&.items&.sole
      expect(line).to be_present
      expect([ line.quantity, line.unit_price, line.total_cost, line.entered_quantity, line.packaging_level ])
        .to eq([ 240, 1, 240, 2, level_of(razor, "carton") ])
    end

    it "pre-fills the receipt in the purchase unit and shows ordered / remaining in it" do
      get new_inventory_goods_receipt_path(purchase_request_id: request.id)
      row = doc.at_css("[data-testid='gr-request-line']")
      expect(row.at_css("[data-testid='gr-line-ordered']").text.squish).to eq("2 cartons 240 pcs")
      expect(row.at_css("input[name*='[entered_quantity]']")["value"]).to eq("2")
      expect(row.at_css("select[name*='[packaging_level_id]'] option[selected]")["value"]).to eq(level_of(razor, "carton").id.to_s)
      expect(row.at_css("[data-testid='gr-add-unit-row']")).to be_present
    end

    it "after receiving 1 carton + 6 boxes the request shows 0.5 carton remaining" do
      line = request.items.sole
      receipt = business.goods_receipts.build(warehouse: main, received_on: Date.current, purchase_request: request,
                                              supplier: business.suppliers.create!(name: "Acme"))
      receipt.items.build(product: razor, purchase_request_item: line, entered_quantity: 1, packaging_level: level_of(razor, "carton"), entered_unit_cost: 120)
      receipt.items.build(product: razor, purchase_request_item: line, entered_quantity: 6, packaging_level: level_of(razor, "box"), entered_unit_cost: 10)
      expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok

      get inventory_purchase_request_path(request)
      expect(doc.at_css("[data-testid='line-remaining']").text.squish).to eq("0.5 carton 60 pcs")
      expect(doc.at_css("[data-testid='line-quantity']").text.squish).to eq("2 cartons 240 pcs")
    end
  end

  describe "product page and numbers" do
    it "shows the packaging on hand per warehouse and the unit cost without decimal zeros" do
      receive_units!(product: razor, warehouse: main, lines: [ [ "carton", 1, 120 ], [ "box", 2, 10 ], [ nil, 5, 1 ] ])
      get inventory_product_path(razor)
      expect(doc.at_css("[data-testid='packaging-on-hand']").text.squish).to include("Main", "1 carton · 2 boxes · 5 pcs (145 pcs)")
      expect(doc.at_css("[data-testid='product-average-cost']").text.squish).to eq("SAR 1")
    end

    it "formats unit costs with up to 8 decimals, never scientific (Decisions 11, 18)" do
      expect(%w[25.00000000 25.50000000 0.70000000 0.70400000 0.00000125].map { |v| CostFormat.unit(BigDecimal(v)) })
        .to eq(%w[25 25.5 0.7 0.704 0.00000125])
    end

    it "the movements CSV writes fixed-point numbers (BUG-072)" do
      shampoo = business.products.create!(name: "Shampoo", sku: "SH-2", initial_cost_price: 0, average_cost_price: 0, unit_of_measure: "ml")
      receipt = business.goods_receipts.build(warehouse: main, received_on: Date.current)
      receipt.items.build(product: shampoo, quantity: 4260, unit_cost: BigDecimal("0.07042254"))
      Inventory::GoodsReceiptPoster.new(receipt).call
      get inventory_movements_report_export_path(file: "csv")
      expect(response.body).to include("0.07042254")
      expect(response.body).not_to match(/\d\.\d+e-?\d/)
    end
  end
end
