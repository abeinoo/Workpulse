require "rails_helper"

# The product's Amount beside its Measure (products.measure_amount): the size
# or packaging, shown as "355 ml" / "0.5 kg". Optional, positive when given,
# decimals allowed; never touches stock quantities.
RSpec.describe "Product amount and measure", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Main", kind: "central") }

  def doc = Nokogiri::HTML(response.body)
  def build(**attrs) = business.products.build({ name: "P", sku: "P-#{SecureRandom.hex(2)}", initial_cost_price: 1, average_cost_price: 1 }.merge(attrs))

  before { sign_in owner }

  describe "the model" do
    it "accepts a positive amount (decimals too), none at all, and refuses zero or negative" do
      expect(build(measure_amount: 355, unit_of_measure: "ml")).to be_valid
      expect(build(measure_amount: BigDecimal("0.5"), unit_of_measure: "kg")).to be_valid
      expect(build(measure_amount: nil)).to be_valid
      expect(build(measure_amount: "")).to be_valid.and(have_attributes(measure_amount: nil))
      expect(build(measure_amount: 0)).not_to be_valid
      expect(build(measure_amount: -1)).not_to be_valid
    end

    it "an existing product keeps no amount (nothing back-filled) and the database refuses a non-positive one" do
      product = build.tap(&:save!)
      expect(product.reload.measure_amount).to be_nil
      expect { product.update_column(:measure_amount, 0) }.to raise_error(ActiveRecord::StatementInvalid, /products_measure_amount_positive/)
    end
  end

  describe "New / Edit" do
    it "shows Amount beside Measure in both languages" do
      get new_inventory_product_path
      pair = doc.at_css("[data-testid='product-measurement'] .measure-pair")
      expect(pair.css("input[type='number'][name='product[measure_amount]'], select[name='product[unit_of_measure]']").size).to eq(2)
      expect(pair.text).to include("Amount", "Measure")

      owner.update!(preferred_locale: "ar")
      get new_inventory_product_path
      expect(response.body).to include('dir="rtl"', "المقدار", "وحدة القياس")
      expect(response.body).not_to include("translation missing")
    end

    it "creates and edits a product with an amount and measure, shown again on Edit and on the product page" do
      post inventory_products_path, params: { product: { name: "Cola", sku: "CO-1", initial_cost_price: 1, measure_amount: "355", unit_of_measure: "ml" } }
      product = business.products.find_by!(sku: "CO-1")
      expect([ product.measure_amount, product.unit_of_measure ]).to eq([ 355, "ml" ])

      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='product-measure']").text.squish).to include("355 ml")
      get inventory_products_path
      expect(doc.at_css("[data-testid='product-measurement']").text).to include("355 ml")

      patch inventory_product_path(product), params: { product: { name: "Cola", sku: "CO-1", measure_amount: "0.5", unit_of_measure: "kg" } }
      expect([ product.reload.measure_amount, product.unit_of_measure ]).to eq([ BigDecimal("0.5"), "kg" ])
      get edit_inventory_product_path(product)
      expect(doc.at_css("input[name='product[measure_amount]']")["value"]).to eq("0.5")
      expect(doc.at_css("select[name='product[unit_of_measure]'] option[selected]")["value"]).to eq("kg")
      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='product-measure']").text.squish).to include("0.5 kg")
    end

    it "the amount is optional: blank saves, and the product page shows the measure's name" do
      post inventory_products_path, params: { product: { name: "Chair", sku: "CH-1", initial_cost_price: 1, measure_amount: "", unit_of_measure: "pieces" } }
      product = business.products.find_by!(sku: "CH-1")
      expect(product.measure_amount).to be_nil
      get inventory_product_path(product)
      expect(doc.at_css("[data-testid='product-measure']").text).to include("A whole product (piece)")
      get inventory_products_path
      expect(doc.css("[data-testid='product-measurement']")).to be_empty
    end

    it "refuses zero or a negative amount with a message, changing nothing" do
      product = build(measure_amount: 1, unit_of_measure: "l").tap(&:save!)
      %w[0 -2].each do |amount|
        patch inventory_product_path(product), params: { product: { name: product.name, sku: product.sku, measure_amount: amount } }
        expect(response).to have_http_status(:unprocessable_entity)
        expect(product.reload.measure_amount).to eq(1)
      end
    end

    it "never changes stock: quantities and movements stay exactly as they were" do
      product = build(unit_of_measure: "ml").tap(&:save!)
      receipt = business.goods_receipts.build(warehouse: warehouse, received_on: Date.current)
      receipt.items.build(product: product, quantity: 12, unit_cost: 1)
      expect(Inventory::GoodsReceiptPoster.new(receipt).call).to be_ok
      before = [ InventoryMovement.order(:id).map(&:attributes), Inventory::StockLevels.new(product).by_warehouse ]

      patch inventory_product_path(product), params: { product: { name: product.name, sku: product.sku, measure_amount: "500", unit_of_measure: "ml" } }
      expect(product.reload.measure_amount).to eq(500)
      expect([ InventoryMovement.order(:id).map(&:attributes), Inventory::StockLevels.new(product).by_warehouse ]).to eq(before)
    end
  end
end
