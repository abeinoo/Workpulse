require "rails_helper"

RSpec.describe "Inventory product variants", type: :request do
  let(:business) { create(:business) }
  let(:owner)    { create(:user, :super_admin, business: business) }
  let!(:product) do
    business.products.create!(name: "Face Wash", sku: "FW-1",
                               initial_cost_price: 10, average_cost_price: 10)
  end

  before { sign_in owner }

  # ── Product create / update with variant nested attributes ──────────────────

  describe "POST /inventory/products (with variants)" do
    it "creates a product with variants" do
      post inventory_products_path, params: {
        product: {
          name: "Body Lotion", sku: "BL-1",
          initial_cost_price: 15, average_cost_price: 15,
          product_variants_attributes: {
            "0" => { name: "Rose",    sku: "BL-ROSE",   active: "1" },
            "1" => { name: "Jasmine", sku: "BL-JASMINE", active: "1" }
          }
        }
      }
      lotion = business.products.find_by(sku: "BL-1")
      expect(lotion).to be_present
      expect(lotion.product_variants.count).to eq(2)
      expect(lotion.product_variants.pluck(:name)).to contain_exactly("Rose", "Jasmine")
    end
  end

  describe "PATCH /inventory/products/:id (variants)" do
    it "adds a variant to an existing product" do
      patch inventory_product_path(product), params: {
        product: {
          product_variants_attributes: {
            "0" => { name: "Honey", sku: "", active: "1" }
          }
        }
      }
      expect(product.product_variants.count).to eq(1)
      expect(product.product_variants.first.name).to eq("Honey")
    end

    it "deactivates an existing variant" do
      variant = product.product_variants.create!(name: "Charcoal", active: true)
      patch inventory_product_path(product), params: {
        product: {
          product_variants_attributes: {
            "0" => { id: variant.id, name: "Charcoal", active: "0" }
          }
        }
      }
      expect(variant.reload.active).to be false
    end

    it "destroys a variant via _destroy flag" do
      variant = product.product_variants.create!(name: "Mint")
      patch inventory_product_path(product), params: {
        product: {
          product_variants_attributes: {
            "0" => { id: variant.id, name: "Mint", _destroy: "1" }
          }
        }
      }
      expect(ProductVariant.exists?(variant.id)).to be false
    end

    it "assigns a barcode to a variant" do
      variant = product.product_variants.create!(name: "Honey")
      patch inventory_product_path(product), params: {
        product: {
          product_barcodes_attributes: {
            "0" => { barcode: "VAR-EAN-001", barcode_type: "manufacturer",
                     is_primary: "1", variant_id: variant.id.to_s }
          }
        }
      }
      pb = product.product_barcodes.find_by(barcode: "VAR-EAN-001")
      expect(pb).to be_present
      expect(pb.variant_id).to eq(variant.id)
    end
  end

  # ── Barcode lookup returns variant info ────────────────────────────────────

  describe "GET /inventory/barcode_lookup" do
    it "returns variant_id and variant_name when barcode belongs to a variant" do
      variant = product.product_variants.create!(name: "Honey")
      product.product_barcodes.create!(
        barcode: "VAR-SCAN-001", barcode_type: "manufacturer",
        is_primary: true, variant_id: variant.id
      )
      get inventory_barcode_lookup_path, params: { code: "VAR-SCAN-001" }, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["variant_id"]).to eq(variant.id)
      expect(body["variant_name"]).to eq("Honey")
    end

    it "returns nil variant fields when barcode is product-level" do
      product.product_barcodes.create!(
        barcode: "PROD-SCAN-001", barcode_type: "manufacturer", is_primary: true
      )
      get inventory_barcode_lookup_path, params: { code: "PROD-SCAN-001" }, as: :json
      body = JSON.parse(response.body)
      expect(body["variant_id"]).to be_nil
      expect(body["variant_name"]).to be_nil
    end
  end

  # ── Products index search ──────────────────────────────────────────────────

  describe "GET /inventory/products (search)" do
    let!(:other_product) do
      business.products.create!(name: "Unrelated", sku: "UR-1",
                                 initial_cost_price: 5, average_cost_price: 5)
    end

    it "finds products by variant name" do
      product.product_variants.create!(name: "Honey Rose", active: true)
      get inventory_products_path, params: { q: "Honey Rose" }
      expect(response.body).to include("Face Wash")
      expect(response.body).not_to include("Unrelated")
    end

    it "finds products by variant SKU" do
      product.product_variants.create!(name: "Honey", sku: "FW-HNY", active: true)
      get inventory_products_path, params: { q: "FW-HNY" }
      expect(response.body).to include("Face Wash")
      expect(response.body).not_to include("Unrelated")
    end

    it "finds products by product name" do
      get inventory_products_path, params: { q: "Face Wash" }
      expect(response.body).to include("Face Wash")
      expect(response.body).not_to include("Unrelated")
    end

    it "finds products by product SKU" do
      get inventory_products_path, params: { q: "FW-1" }
      expect(response.body).to include("Face Wash")
      expect(response.body).not_to include("Unrelated")
    end

    it "finds products by barcode" do
      product.product_barcodes.create!(barcode: "SRCH-BC-001", barcode_type: "manufacturer", is_primary: true)
      get inventory_products_path, params: { q: "SRCH-BC-001" }
      expect(response.body).to include("Face Wash")
      expect(response.body).not_to include("Unrelated")
    end

    it "returns no results when nothing matches" do
      get inventory_products_path, params: { q: "xyznothing" }
      expect(response.body).not_to include("Face Wash")
    end
  end

  # ── Variant-aware barcode generation ──────────────────────────────────────

  describe "POST /inventory/products/:id/generate_barcode" do
    it "generates a product-level barcode when no variant_id given" do
      post generate_barcode_inventory_product_path(product), as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["variant_id"]).to be_nil
    end

    it "generates a barcode assigned to a specific variant" do
      variant = product.product_variants.create!(name: "Honey")
      post generate_barcode_inventory_product_path(product),
           params: { variant_id: variant.id }, as: :json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["variant_id"]).to eq(variant.id)
      pb = product.product_barcodes.find(body["id"])
      expect(pb.variant_id).to eq(variant.id)
    end

    it "returns 404 when variant_id does not belong to this product" do
      other = business.products.create!(name: "Other", sku: "OTH-1", initial_cost_price: 1, average_cost_price: 1)
      other_variant = other.product_variants.create!(name: "Slim")
      post generate_barcode_inventory_product_path(product),
           params: { variant_id: other_variant.id }, as: :json
      expect(response).to have_http_status(:not_found)
    end

    it "auto-promotes as primary when no primary exists for that variant group" do
      variant = product.product_variants.create!(name: "Charcoal")
      post generate_barcode_inventory_product_path(product),
           params: { variant_id: variant.id }, as: :json
      body = JSON.parse(response.body)
      expect(body["is_primary"]).to be true
    end

    it "does not mark primary when variant group already has one" do
      variant = product.product_variants.create!(name: "Mint")
      product.product_barcodes.create!(barcode: "MINT-EXISTING", barcode_type: "manufacturer",
                                        is_primary: true, variant_id: variant.id)
      post generate_barcode_inventory_product_path(product),
           params: { variant_id: variant.id }, as: :json
      body = JSON.parse(response.body)
      expect(body["is_primary"]).to be false
    end
  end

  # ── Primary barcode enforcement per variant group ──────────────────────────

  describe "primary barcode scoping" do
    it "allows one primary per product and one primary per variant simultaneously" do
      variant = product.product_variants.create!(name: "Honey")

      product_pb  = product.product_barcodes.create!(barcode: "PROD-PRI-001", barcode_type: "manufacturer", is_primary: true)
      variant_pb  = product.product_barcodes.create!(barcode: "VAR-PRI-001",  barcode_type: "manufacturer", is_primary: true, variant_id: variant.id)

      expect(product_pb.reload.is_primary).to be true
      expect(variant_pb.reload.is_primary).to be true
    end

    it "does not cross-demote primaries between product-level and variant barcodes" do
      variant = product.product_variants.create!(name: "Charcoal")
      product_pb = product.product_barcodes.create!(barcode: "PROD-NX-001", barcode_type: "manufacturer", is_primary: true)
      var_pb     = product.product_barcodes.create!(barcode: "VAR-NX-001",  barcode_type: "manufacturer", is_primary: true, variant_id: variant.id)

      # Mark a second product-level barcode as primary — should demote product_pb only
      product_pb2 = product.product_barcodes.create!(barcode: "PROD-NX-002", barcode_type: "internal", is_primary: false)
      product_pb2.update!(is_primary: true)

      expect(product_pb.reload.is_primary).to be false   # demoted within product group
      expect(var_pb.reload.is_primary).to be true        # untouched — different variant group
    end
  end
end
