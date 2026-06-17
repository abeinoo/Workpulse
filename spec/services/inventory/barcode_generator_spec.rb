require "rails_helper"

RSpec.describe Inventory::BarcodeGenerator do
  describe ".next_code" do
    it "starts at 10000001 when no internal barcodes exist" do
      expect(described_class.next_code).to eq("10000001")
    end

    it "increments from the highest existing internal barcode" do
      business = create(:business)
      product  = business.products.create!(name: "P", sku: "P-1", initial_cost_price: 1, average_cost_price: 1)
      product.product_barcodes.create!(barcode: "10000005", barcode_type: "internal", is_primary: true)

      expect(described_class.next_code).to eq("10000006")
    end

    it "ignores manufacturer and carton barcodes in the sequence" do
      business = create(:business)
      product  = business.products.create!(name: "Q", sku: "Q-1", initial_cost_price: 1, average_cost_price: 1)
      product.product_barcodes.create!(barcode: "99999999", barcode_type: "manufacturer", is_primary: true)

      expect(described_class.next_code).to eq("10000001")
    end

    it "ignores non-numeric internal barcodes" do
      business = create(:business)
      product  = business.products.create!(name: "R", sku: "R-1", initial_cost_price: 1, average_cost_price: 1)
      product.product_barcodes.create!(barcode: "ABC-123", barcode_type: "internal", is_primary: true)

      expect(described_class.next_code).to eq("10000001")
    end

    it "never returns a code below the minimum start" do
      expect(described_class.next_code.to_i).to be >= Inventory::BarcodeGenerator::INTERNAL_START
    end
  end
end
