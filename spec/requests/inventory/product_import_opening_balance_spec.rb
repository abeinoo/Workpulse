require "rails_helper"

# The product import page when the opening-balance adjustment is refused:
# previously a 500 (NoMethodError on a nil result); now a redirect back to
# the import page naming the warehouse, the product and the reason.
RSpec.describe "Product import — refused opening balance", type: :request do
  let(:business)   { create(:business) }
  let!(:owner)     { create(:user, :owner, business: business) }
  let!(:warehouse) { business.warehouses.create!(name: "Nasr City WH", kind: "central") }

  def upload(csv)
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "products.csv")
    post run_import_inventory_products_path, params: { file: file, warehouse_id: warehouse.id }
  end

  before { sign_in owner }

  it "redirects to the import page with an actionable message and imports nothing" do
    expect { upload("Product Name,SKU,Initial Cost,Current Stock\nFree Widget,FW-1,0,5\n") }
      .not_to change(Product, :count)

    expect(response).to redirect_to(import_inventory_products_path)
    expect(flash[:alert]).to eq(
      I18n.t("inventory.imports.opening_balance_refused",
             warehouse: "Nasr City WH", errors: "Opening balance for Free Widget requires a unit cost")
    )
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Free Widget").and include("Nasr City WH")
  end

  it "shows the result page for a valid import, as before" do
    upload("Product Name,SKU,Initial Cost,Current Stock\nGood Widget,GW-1,5,3\n")
    expect(response).to have_http_status(:ok)
    expect(business.products.find_by!(sku: "GW-1").stock_in(warehouse)).to eq(3)
  end
end
