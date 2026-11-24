require "rails_helper"

# Product measurement is two fields on the product form — Unit of Measure and
# Amount — both editable at any time. No packaging, no conversion: changing
# them changes only those two fields; stock, movements and costs are never
# touched, and documents show quantities as plain numbers of inventory units.
RSpec.describe "Product measure editing (Unit of Measure + Amount)", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main", kind: "central") }

  def doc = Nokogiri::HTML(response.body)
  def amount_input  = doc.at_css("input[type='number'][name='product[measure_amount]']")
  def amount_blank  = doc.at_css("input[type='hidden'][name='product[measure_amount]']")
  def amount_group  = doc.at_css("[data-testid='product-measure-amount-group']")
  def amount_suffix = doc.at_css("[data-testid='product-measure-amount-suffix']").text.strip
  def selected_unit = doc.at_css("select[name='product[unit_of_measure]'] option[selected]")["value"]

  def create_product(sku, unit, amount)
    post inventory_products_path, params: { product: { name: "P #{sku}", sku: sku, initial_cost_price: 1, unit_of_measure: unit, measure_amount: amount } }
    business.products.find_by!(sku: sku)
  end

  def update_product(product, **attrs)
    patch inventory_product_path(product), params: { product: { name: product.name, sku: product.sku }.merge(attrs) }
  end

  before { sign_in owner }

  describe "creating" do
    it "unit = ml with amount 355, shown on the product page and the list" do
      product = create_product("SH-1", "ml", "355")
      expect([ product.unit_of_measure, product.measure_amount ]).to eq([ "ml", 355 ])
      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='product-measure']").text.squish).to include("355 ml")
      get inventory_products_path
      expect(doc.at_css("[data-testid='product-measurement']").text).to include("355 ml")
    end

    it "unit = g with amount 500" do
      product = create_product("HP-1", "g", "500")
      expect([ product.unit_of_measure, product.measure_amount ]).to eq([ "g", 500 ])
      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='product-measure']").text.squish).to include("500 g")
    end

    it "unit = pieces with no amount; the Amount field is hidden and not submitted" do
      product = create_product("CH-1", "pieces", "")
      expect([ product.unit_of_measure, product.measure_amount ]).to eq([ "pieces", nil ])
      get edit_inventory_product_path(product)
      expect(amount_group.has_attribute?("hidden")).to be(true) # a bare boolean attribute (empty value)
      expect(amount_input["disabled"]).to be_present
      expect(amount_blank["disabled"]).to be_nil
      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='product-measure']").text).to include("A whole product (piece)")
    end
  end

  describe "editing" do
    let(:product) do
      business.products.create!(name: "Cream", sku: "CR-1", initial_cost_price: 1, average_cost_price: 1, unit_of_measure: "ml", measure_amount: 355)
    end

    it "changes unit and amount directly, shown back on Edit" do
      update_product(product, unit_of_measure: "g", measure_amount: "500")
      expect(response).to redirect_to(inventory_product_path(product))
      expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "g", 500 ])

      update_product(product, unit_of_measure: "cm", measure_amount: "60")
      expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "cm", 60 ])
      get edit_inventory_product_path(product)
      expect([ selected_unit, amount_input["value"], amount_suffix ]).to eq([ "cm", "60", "cm" ])
    end

    it "switching to pieces keeps no stale amount" do
      update_product(product, unit_of_measure: "pieces", measure_amount: "")
      expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "pieces", nil ])

      product.update_column(:measure_amount, 10) # an amount left over on a piece
      get edit_inventory_product_path(product)
      expect(amount_input["value"]).to be_nil    # never shown in the hidden field
      update_product(product, unit_of_measure: "pieces", measure_amount: "")
      expect(product.reload.measure_amount).to be_nil
    end

    it "labels and suffixes in English and Arabic (RTL)" do
      get edit_inventory_product_path(product)
      group = doc.at_css("[data-testid='product-measurement']")
      expect(group.at_css("label[for='product_unit_of_measure']").text).to eq("Measure")
      expect(group.at_css("label[for='product_measure_amount']").text).to eq("Amount")
      expect(amount_suffix).to eq("ml")
      expect(doc.at_css("select[name='product[unit_of_measure]'] option[value='g']")["data-short"]).to eq("g")

      owner.update!(preferred_locale: "ar")
      get edit_inventory_product_path(product)
      expect(doc.at_css("html")["dir"]).to eq("rtl")
      group = doc.at_css("[data-testid='product-measurement']")
      expect(group.at_css("label[for='product_unit_of_measure']").text).to eq("وحدة القياس")
      expect(group.at_css("label[for='product_measure_amount']").text).to eq("المقدار")
      expect(amount_suffix).to eq("مل")
      expect(response.body).not_to include("translation missing", "Translation missing")
    end

    it "the form has only Unit of Measure and Amount: no packaging or conversion anywhere" do
      get edit_inventory_product_path(product)
      group = doc.at_css("[data-testid='product-measurement']")
      expect(group.css("select, input:not([type='hidden'])").map { |f| f["name"] }).to eq(%w[product[unit_of_measure] product[measure_amount]])
      expect(doc.css("[data-testid='packaging-section'], [data-testid='unit-change'], [name^='packaging'], [name^='unit_change']")).to be_empty
      get inventory_product_path(product)
      expect(doc.css("[data-testid='convert-unit'], [data-testid='packaging-card']")).to be_empty
      expect { Rails.application.routes.recognize_path("/inventory/unit_conversions") }.to raise_error(ActionController::RoutingError)
      expect { Rails.application.routes.recognize_path("/inventory/products/#{product.id}/packaging") }.to raise_error(ActionController::RoutingError)
    end
  end

  describe "with stock history" do
    let(:product) { business.products.create!(name: "Rope", sku: "RP-1", initial_cost_price: 0, average_cost_price: 0) }
    let!(:receipt) do
      business.goods_receipts.build(warehouse: warehouse, received_on: Date.current).tap do |r|
        r.items.build(product: product, quantity: 10, unit_cost: 6)
        expect(Inventory::GoodsReceiptPoster.new(r, actor: owner).call).to be_ok
      end
    end

    it "the unit changes directly; historical movements, stock and average cost stay exactly as they were" do
      movements = InventoryMovement.order(:id).map(&:attributes)
      stock     = Inventory::StockLevels.new(product).by_warehouse
      average   = product.reload.average_cost_price

      update_product(product, unit_of_measure: "cm", measure_amount: "60")
      expect(response).to redirect_to(inventory_product_path(product))
      expect([ product.reload.unit_of_measure, product.measure_amount ]).to eq([ "cm", 60 ])
      expect(InventoryMovement.order(:id).map(&:attributes)).to eq(movements)
      expect(Inventory::StockLevels.new(product).by_warehouse).to eq(stock)
      expect(product.average_cost_price).to eq(average)
    end

    it "documents show and take quantities as numbers of inventory units, never labelled with the measure" do
      update_product(product, unit_of_measure: "kg")
      get inventory_goods_receipt_path(receipt)
      expect(doc.css("td").map { |td| td.text.squish }).to include("10")
      expect(doc.text.squish).not_to include("10 kg")

      later = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      later.items.build(product: product, quantity: "2.5", unit_cost: 6)
      expect(Inventory::GoodsReceiptPoster.new(later, actor: owner).call).to be_ok
      expect(product.reload.current_stock).to eq(BigDecimal("12.5"))
      get inventory_goods_receipt_path(later)
      expect(doc.css("td").map { |td| td.text.squish }).to include("2.5")
      expect(doc.text.squish).not_to include("2.5 kg")
    end
  end
end
