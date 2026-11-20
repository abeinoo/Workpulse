require "rails_helper"

# The product import page: low-stock / reorder columns land in the central
# warehouse's settings; refusals redirect back with an actionable message and
# import nothing.
RSpec.describe "Product import — central warehouse settings", type: :request do
  let(:business) { create(:business) }
  let!(:owner)   { create(:user, :owner, business: business) }
  let!(:central) { business.warehouses.create!(name: "Main Central", kind: "central") }

  def upload(csv, warehouse_id: nil)
    file = Rack::Test::UploadedFile.new(StringIO.new(csv), "text/csv", original_filename: "products.csv")
    post run_import_inventory_products_path, params: { file: file, warehouse_id: warehouse_id }
  end

  let(:file) { "Product Name,SKU,Initial Cost,Low Stock Level,Reorder Quantity\nShampoo,SH-1,5,2,6\n" }

  before { sign_in owner }

  it "imports and saves the values as the central warehouse's settings, shown on the product Edit page" do
    upload(file)
    expect(response).to have_http_status(:ok)
    product = business.products.find_by!(sku: "SH-1")
    expect(ProductWarehouseSetting.find_by!(product: product, warehouse: central)).to have_attributes(low_stock_level: 2, reorder_quantity: 6)

    get edit_inventory_product_path(product)
    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("#pws-#{central.id}-low")["value"]).to eq("2")
    expect(doc.at_css("#pws-#{central.id}-reorder")["value"]).to eq("6")
  end

  it "explains the central-settings columns on the import page (English and Arabic)" do
    get import_inventory_products_path
    expect(response.body).to include(ERB::Util.html_escape(I18n.t("inventory.imports.central_settings.hint")))
    owner.update!(preferred_locale: "ar")
    get import_inventory_products_path
    expect(response.body).to include(ERB::Util.html_escape(I18n.t("inventory.imports.central_settings.hint", locale: :ar)))
  end

  it "without an active central warehouse: redirects with an actionable message and imports nothing" do
    central.update!(status: "inactive")
    expect { upload(file) }.not_to change(Product, :count)
    expect(response).to redirect_to(import_inventory_products_path)
    expect(flash[:alert]).to eq(I18n.t("inventory.imports.central_settings.no_central_warehouse"))
  end

  it "with several active central warehouses: refuses, imports nothing" do
    business.warehouses.create!(name: "Second Central", kind: "central")
    expect { upload(file) }.not_to change(Product, :count)
    expect(flash[:alert]).to eq(I18n.t("inventory.imports.central_settings.ambiguous_central_warehouse"))
  end

  it "for a user who cannot manage the central warehouse: names it, imports nothing" do
    role = business.permission_roles.create!(name: "Importer", permissions: %w[view_inventory manage_inventory], role_type: "area_manager")
    clerk = create(:user, business: business)
    clerk.update_column(:permission_role_id, role.id)
    sign_in clerk
    expect { upload(file) }.not_to change(ProductWarehouseSetting, :count)
    expect(Product.where(sku: "SH-1")).to be_empty
    expect(response).to redirect_to(import_inventory_products_path)
    expect(flash[:alert]).to eq(I18n.t("inventory.imports.central_settings.not_authorized", warehouse: "Main Central"))
  end
end
