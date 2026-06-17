require "rails_helper"

RSpec.describe ProductBarcode, type: :model do
  let(:business) { create(:business) }
  let(:product)  { business.products.create!(name: "Shampoo", sku: "SH-1", initial_cost_price: 5, average_cost_price: 5) }

  def build_barcode(attrs = {})
    product.product_barcodes.build({ barcode: "1234567890", barcode_type: "manufacturer", is_primary: false }.merge(attrs))
  end

  describe "validations" do
    it "is valid with all required attributes" do
      expect(build_barcode.valid?).to be true
    end

    it "requires barcode to be present" do
      pb = build_barcode(barcode: "")
      expect(pb.valid?).to be false
      expect(pb.errors[:barcode]).to be_present
    end

    it "enforces maximum barcode length of 100 characters" do
      pb = build_barcode(barcode: "A" * 101)
      expect(pb.valid?).to be false
      expect(pb.errors[:barcode]).to be_present
    end

    it "rejects invalid barcode_type values" do
      pb = build_barcode(barcode_type: "ean_13")
      expect(pb.valid?).to be false
      expect(pb.errors[:barcode_type]).to be_present
    end

    it "accepts all valid barcode types" do
      ProductBarcode::BARCODE_TYPES.each do |type|
        pb = build_barcode(barcode_type: type)
        expect(pb.valid?).to be(true), "expected #{type} to be valid"
      end
    end

    it "enforces global barcode uniqueness (case-insensitive)" do
      product.product_barcodes.create!(barcode: "UNIQUE-001", barcode_type: "manufacturer", is_primary: true)
      pb = build_barcode(barcode: "unique-001")
      expect(pb.valid?).to be false
      expect(pb.errors[:barcode]).to be_present
    end

    it "allows the same barcode to be updated without triggering uniqueness error" do
      pb = product.product_barcodes.create!(barcode: "REUSE-001", barcode_type: "manufacturer", is_primary: true)
      pb.barcode_type = "internal"
      expect(pb.valid?).to be true
    end
  end

  describe "barcode normalization" do
    it "strips leading and trailing whitespace from barcode" do
      pb = product.product_barcodes.create!(barcode: "  6291041500213  ", barcode_type: "manufacturer", is_primary: true)
      expect(pb.barcode).to eq("6291041500213")
    end
  end

  describe "barcode_type inference" do
    it "defaults barcode_type to manufacturer when not specified" do
      pb = product.product_barcodes.create!(barcode: "AUTO-TYPE", is_primary: true)
      expect(pb.barcode_type).to eq("manufacturer")
    end

    it "does not override an explicitly set barcode_type" do
      pb = product.product_barcodes.create!(barcode: "INTERNAL-001", barcode_type: "internal", is_primary: true)
      expect(pb.barcode_type).to eq("internal")
    end
  end

  describe "#demote_siblings" do
    it "demotes other primary barcodes when a new one is marked primary" do
      first  = product.product_barcodes.create!(barcode: "FIRST-001",  barcode_type: "manufacturer", is_primary: true)
      second = product.product_barcodes.create!(barcode: "SECOND-001", barcode_type: "internal",     is_primary: false)

      second.update!(is_primary: true)

      expect(first.reload.is_primary).to be false
      expect(second.reload.is_primary).to be true
    end
  end

  describe "primary enforcement via Product#ensure_single_primary_barcode" do
    it "keeps only one primary when multiple are submitted" do
      product.product_barcodes.create!(barcode: "FIRST",  barcode_type: "manufacturer", is_primary: true)
      product.product_barcodes.create!(barcode: "SECOND", barcode_type: "internal",     is_primary: true)

      expect(product.product_barcodes.reload.where(is_primary: true).count).to eq(1)
    end

    it "auto-promotes the first barcode to primary when none are marked primary" do
      product.update!(
        product_barcodes_attributes: [
          { barcode: "ONLY-ONE", barcode_type: "manufacturer", is_primary: false }
        ]
      )
      expect(product.product_barcodes.reload.where(is_primary: true).count).to eq(1)
    end
  end
end
