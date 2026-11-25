require "rails_helper"

# The product Measure (products.unit_of_measure): an informational attribute
# describing what one inventory unit contains. Chosen on New / Edit from 12
# stable codes (labels translated), "pieces" (a whole product) by default;
# accepted by the product import (optional column). It never labels an
# inventory quantity: documents, stock counts and reports show plain numbers of
# inventory units, and no quantity is ever converted.
RSpec.describe "Product measure", type: :request do
  let(:business)  { create(:business) }
  let!(:owner)    { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main", kind: "central") }
  let(:shampoo)   { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 2, average_cost_price: 2, unit_of_measure: "ml") }

  def doc = Nokogiri::HTML(response.body)
  def measure_select = doc.at_css("select[name='product[unit_of_measure]']")

  before { sign_in owner }

  describe "the model" do
    it "accepts exactly the 12 measures, defaults to a whole product, and refuses anything else" do
      expect(Product::UNITS_OF_MEASURE).to eq(%w[ml l fl_oz g kg gal oz lb cm ft in pieces])
      plain = business.products.create!(name: "Chair", sku: "CH-1", initial_cost_price: 1, average_cost_price: 1)
      expect(plain.unit_of_measure).to eq("pieces")
      expect(business.products.build(name: "X", sku: "X-1", unit_of_measure: "litre")).not_to be_valid
      expect(business.products.build(name: "X", sku: "X-2", unit_of_measure: "")).not_to be_valid
    end
  end

  describe "New / Edit" do
    it "offers every measure, defaulting to a whole product on New" do
      get new_inventory_product_path
      options = measure_select.css("option")
      expect(options.map { |o| o["value"] }).to eq(Product::UNITS_OF_MEASURE)
      expect(options.map(&:text)).to include("Millilitres (ml)", "Fluid ounces (fl oz)", "A whole product (piece)")
      expect(measure_select.at_css("option[selected]")["value"]).to eq("pieces")
      expect(options.map { |o| o["value"] }).not_to include("") # always a measure (no empty choice)
      # In the Basic Info grid (the product editor's .pe-grid), beside name / SKU / brand.
      expect(measure_select.ancestors(".pe-grid").first.at_css("input[name='product[sku]']")).to be_present
    end

    it "creates and edits a product with each measure, showing the saved one on Edit" do
      Product::UNITS_OF_MEASURE.each_with_index do |code, i|
        post inventory_products_path, params: { product: { name: "P #{code}", sku: "M-#{i}", initial_cost_price: 1, unit_of_measure: code } }
        product = business.products.find_by!(sku: "M-#{i}")
        expect(product.unit_of_measure).to eq(code)

        other = Product::UNITS_OF_MEASURE[(i + 1) % Product::UNITS_OF_MEASURE.size]
        patch inventory_product_path(product), params: { product: { name: product.name, sku: product.sku, unit_of_measure: other } }
        expect(product.reload.unit_of_measure).to eq(other)
        get edit_inventory_product_path(product)
        expect(measure_select.at_css("option[selected]")["value"]).to eq(other)
      end
    end

    it "refuses an unknown measure and keeps the product unchanged" do
      patch inventory_product_path(shampoo), params: { product: { name: "Shampoo", sku: "SH-1", unit_of_measure: "bucket" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(shampoo.reload.unit_of_measure).to eq("ml")
    end

    it "is labelled in Arabic too (right-to-left)" do
      owner.update!(preferred_locale: "ar")
      get edit_inventory_product_path(shampoo)
      expect(response.body).to include('dir="rtl"', "وحدة القياس", "مليلتر (مل)", "منتج كامل (قطعة)")
      expect(response.body).not_to include("translation missing")
      get inventory_product_path(shampoo)
      expect(doc.at_css("[data-testid='product-measure']").text).to include("مليلتر (مل)")
    end
  end

  describe "inventory quantities are numbers of units, never labelled with the measure" do
    def receive!(product, qty)
      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      receipt.items.build(product: product, quantity: qty, unit_cost: 2)
      expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
      receipt
    end

    def cell_texts = doc.css("td").map { |td| td.text.squish }
    def no_measure_label! = expect(cell_texts.grep(/\d ml\z/)).to be_empty

    it "on goods receipts, issues, transfers, adjustments, counts and the stock reports — fractions shown exactly, no measure" do
      receipt = receive!(shampoo, BigDecimal("250.5"))
      get inventory_goods_receipt_path(receipt)
      expect(cell_texts).to include("250.5")
      no_measure_label!

      branch = create(:branch, business: business)
      issue = business.stock_issues.build(warehouse: warehouse, branch: branch, issued_on: Date.current)
      issue.items.build(product: shampoo, quantity: 20)
      approve_and_post_stock_issue(issue)
      get inventory_stock_issue_path(issue)
      expect(cell_texts).to include("20")
      no_measure_label!

      other = business.warehouses.create!(name: "Annex")
      transfer = business.stock_transfers.build(source_warehouse: warehouse, destination_warehouse: other, transferred_on: Date.current)
      transfer.items.build(product: shampoo, quantity: 30)
      expect(post_stock_transfer(transfer)).to be_ok
      get inventory_stock_transfer_path(transfer)
      expect(cell_texts).to include("30")
      no_measure_label!

      adjustment = business.stock_adjustments.build(warehouse: warehouse, adjusted_on: Date.current, reason: "damaged", created_by: owner)
      adjustment.items.build(product: shampoo, quantity_difference: -0.5)
      expect(Inventory::AdjustmentPoster.new(adjustment).call).to be_ok
      get inventory_stock_adjustment_path(adjustment)
      expect(doc.text.squish).to include("-0.5")
      expect(doc.text.squish).not_to include("-0.5 ml")

      get inventory_current_stock_report_path
      expect(cell_texts).to include("230") # every warehouse: 250.5 − 20 − 0.5
      no_measure_label!
      ProductWarehouseSetting.create!(product: shampoo, warehouse: warehouse) # listed on the warehouse's Products tab
      get inventory_warehouse_product_availabilities_path(warehouse)
      expect(doc.text.squish).to include("200")
      expect(doc.text.squish).not_to include("200 ml")
      get inventory_product_path(shampoo)
      expect(doc.text.squish).not_to include("230 ml")

      counter = user_with_stock_permissions(business, :view_inventory, :manage_stock_counts)
      count = record_stock_count!(business: business, warehouse: warehouse, counter: counter, lines: [])
      sign_in counter
      get edit_inventory_stock_count_path(count)
      row = doc.at_css("tbody tr[data-product-id='#{shampoo.id}']")
      expect(row.at_css("[data-measure-label], .qty-unit")).to be_nil
      expect(row.text.squish).to include("200")
      expect(row.text.squish).not_to include("200 ml")
    end

    it "quantity inputs carry no measure, and the product pickers and lookups send none" do
      receipt = business.goods_receipts.create!(warehouse: warehouse, received_on: Date.current,
                                                items_attributes: [ { product_id: shampoo.id, quantity: 1, unit_cost: 2 } ])
      get edit_inventory_goods_receipt_path(receipt)
      line = doc.css("[data-line-items-target='rows'] [data-line-row]").first
      expect(line.at_css("[data-measure-label], .qty-unit")).to be_nil
      expect(line.at_css("option[value='#{shampoo.id}']")["data-measure"]).to be_nil

      get inventory_product_search_path(q: "SH-1"), as: :json
      expect(response.parsed_body.first).not_to have_key("measure")
      get inventory_barcode_lookup_path(code: "SH-1"), as: :json
      expect(response.parsed_body).not_to have_key("measure")
    end

    it "changing a product's measure converts nothing: stock, movements and cost stay exactly as they were" do
      receive!(shampoo, 500)
      before = [ InventoryMovement.order(:id).map(&:attributes), Inventory::StockLevels.new(shampoo).by_warehouse, shampoo.reload.average_cost_price ]
      patch inventory_product_path(shampoo), params: { product: { name: "Shampoo", sku: "SH-1", unit_of_measure: "l" } }
      expect(shampoo.reload.unit_of_measure).to eq("l")
      expect([ InventoryMovement.order(:id).map(&:attributes), Inventory::StockLevels.new(shampoo).by_warehouse, shampoo.average_cost_price ]).to eq(before)
    end
  end

  describe "product import" do
    def import(csv)
      Inventory::Imports::ProductImporter.new(business, csv, user: owner).call
    end

    it "reads the optional Measure column (code, short label or name, English or Arabic); blank = a whole product" do
      csv = <<~CSV
        Product Name,SKU,Measure
        Gel,IM-1,kg
        Toner,IM-2,Fluid ounces (fl oz)
        Oil,IM-3,مل
        Comb,IM-4,
        Towel,IM-5,piece
        Bucket,IM-6,bucketful
      CSV
      result = import(csv)
      expect(business.products.where(sku: %w[IM-1 IM-2 IM-3 IM-4 IM-5]).order(:sku).pluck(:unit_of_measure))
        .to eq(%w[kg fl_oz ml pieces pieces])
      expect(result.skipped.map { |s| [ s.sku, s.reason ] }).to eq([ [ "IM-6", :invalid_measure ] ])
      expect(I18n.t("inventory.imports.reasons.invalid_measure")).not_to include("translation missing")
    end

    it "still imports a file without the Measure column (every product a whole product), and the template lists it" do
      result = import("Product Name,SKU\nChair,OLD-1\n")
      expect(result.created.map(&:unit_of_measure)).to eq(%w[pieces])
      header = CSV.parse_line(Inventory::Imports::ProductImporter.sample_csv.lines.first)
      expect(header).to include("Measure")
    end
  end
end
