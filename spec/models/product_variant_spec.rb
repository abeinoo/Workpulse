require "rails_helper"

RSpec.describe ProductVariant, type: :model do
  let(:business) { create(:business) }
  let(:product)  { business.products.create!(name: "Face Wash", sku: "FW-1", initial_cost_price: 10, average_cost_price: 10) }

  def build_variant(attrs = {})
    product.product_variants.build({ name: "Honey", active: true }.merge(attrs))
  end

  describe "validations" do
    it "is valid with required attributes" do
      expect(build_variant.valid?).to be true
    end

    it "requires name" do
      v = build_variant(name: "")
      expect(v).not_to be_valid
      expect(v.errors[:name]).to be_present
    end

    it "limits name to 200 characters" do
      v = build_variant(name: "A" * 201)
      expect(v).not_to be_valid
      expect(v.errors[:name]).to be_present
    end

    it "limits sku to 80 characters" do
      v = build_variant(sku: "X" * 81)
      expect(v).not_to be_valid
      expect(v.errors[:sku]).to be_present
    end

    it "allows blank sku" do
      expect(build_variant(sku: "")).to be_valid
    end

    it "enforces SKU uniqueness within a product (case-insensitive)" do
      product.product_variants.create!(name: "Charcoal", sku: "FW-CHAR")
      v = build_variant(name: "Honey", sku: "fw-char")
      expect(v).not_to be_valid
      expect(v.errors[:sku]).to be_present
    end

    it "allows the same SKU on different products" do
      other = business.products.create!(name: "Toner", sku: "TN-1", initial_cost_price: 5, average_cost_price: 5)
      other.product_variants.create!(name: "Rose", sku: "VAR-SKU")
      v = build_variant(name: "Honey", sku: "VAR-SKU")
      expect(v).to be_valid
    end
  end

  describe "scopes" do
    before do
      product.product_variants.create!(name: "Active One",   active: true,  position: 2)
      product.product_variants.create!(name: "Inactive One", active: false, position: 1)
      product.product_variants.create!(name: "Active Two",   active: true,  position: 1)
    end

    it ".active returns only active variants" do
      names = ProductVariant.active.where(product: product).pluck(:name)
      expect(names).to include("Active One", "Active Two")
      expect(names).not_to include("Inactive One")
    end

    it ".ordered returns variants sorted by position then name" do
      ordered = product.product_variants.ordered.pluck(:name)
      expect(ordered.index("Active Two")).to be < ordered.index("Active One")
    end
  end

  describe "associations" do
    it "nullifies barcode variant_id when variant is destroyed" do
      variant = product.product_variants.create!(name: "Honey")
      pb = product.product_barcodes.create!(
        barcode: "VAR-BC-001", barcode_type: "manufacturer", is_primary: true,
        variant_id: variant.id
      )
      variant.destroy
      expect(pb.reload.variant_id).to be_nil
    end
  end
end
