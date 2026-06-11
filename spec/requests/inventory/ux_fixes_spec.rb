require "rails_helper"

# Coverage for the three inventory UX fixes: goods-receipt invoice attachments,
# CSV import sample templates, and category description/active management.
RSpec.describe "Inventory UX fixes", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }

  before { sign_in owner }

  describe "goods receipt invoice attachments" do
    let(:warehouse) { business.warehouses.create!(name: "Main", status: "active") }
    let(:product)   { business.products.create!(name: "Soap", sku: "SP-1", initial_cost_price: 3) }

    def upload(filename, type)
      Rack::Test::UploadedFile.new(
        StringIO.new("dummy"), type, original_filename: filename
      )
    end

    it "attaches uploaded invoices to the posted receipt" do
      post inventory_goods_receipts_path, params: {
        goods_receipt: {
          warehouse_id: warehouse.id, received_on: Date.current,
          invoices: [ upload("invoice.pdf", "application/pdf") ],
          items_attributes: { "0" => { product_id: product.id, quantity: 5, unit_cost: 4 } }
        }
      }
      receipt = business.goods_receipts.last
      expect(receipt).to be_present
      expect(receipt.invoices).to be_attached
      expect(receipt.invoices.first.filename.to_s).to eq("invoice.pdf")

      get inventory_goods_receipt_path(receipt)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("invoice.pdf")
    end

    it "rejects a disallowed invoice content type" do
      post inventory_goods_receipts_path, params: {
        goods_receipt: {
          warehouse_id: warehouse.id, received_on: Date.current,
          invoices: [ upload("notes.txt", "text/plain") ],
          items_attributes: { "0" => { product_id: product.id, quantity: 5, unit_cost: 4 } }
        }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(business.goods_receipts.count).to eq(0)
    end
  end

  describe "CSV import sample templates" do
    it "returns a product import sample with the schema headers" do
      get import_template_inventory_products_path
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/csv")
      expect(response.body.lines.first).to start_with("Product Name,SKU")
    end

    it "returns a stock-issue import sample" do
      get import_template_inventory_stock_issues_path
      expect(response).to have_http_status(:ok)
      expect(response.body.lines.first.strip).to eq("SKU,Quantity")
    end
  end

  describe "category description & active" do
    it "creates a category with a description and active flag" do
      post inventory_product_categories_path, params: {
        product_category: { name: "Cleaning", description: "Soaps and detergents", active: "1" }
      }
      category = business.product_categories.find_by!(name: "Cleaning")
      expect(category.description).to eq("Soaps and detergents")
      expect(category.active).to be(true)
    end

    it "excludes inactive categories from the new-product selector but keeps the edited product's own" do
      active   = business.product_categories.create!(name: "Active cat", active: true)
      inactive = business.product_categories.create!(name: "Inactive cat", active: false)

      get new_inventory_product_path
      expect(response.body).to include("Active cat")
      expect(response.body).not_to include("Inactive cat")

      product = business.products.create!(name: "Legacy", sku: "LG-1",
                                          initial_cost_price: 1, product_category: inactive)
      get edit_inventory_product_path(product)
      expect(response.body).to include("Inactive cat")
    end
  end
end
