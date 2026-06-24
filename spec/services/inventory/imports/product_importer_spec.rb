require "rails_helper"

RSpec.describe Inventory::Imports::ProductImporter do
  let(:business) { create(:business) }

  def importer(csv_data, warehouse: nil)
    described_class.new(business, csv_data, warehouse: warehouse)
  end

  def valid_csv(rows = [])
    CSV.generate do |csv|
      csv << %w[Product\ Name SKU Barcode Brand Category Initial\ Cost Current\ Stock Low\ Stock\ Level Reorder\ Quantity]
      rows.each { |r| csv << r }
    end
  end

  # ── UTF-8 BOM (Excel default export) ─────────────────────────────────────
  describe "Excel UTF-8 BOM handling" do
    it "strips the BOM and imports successfully" do
      bom = "\xEF\xBB\xBF"
      csv = bom + valid_csv([["Widget", "W-001", "", "", "", "10.00", "5", "1", "2"]])

      result = importer(csv).call

      expect(result.ok?).to be true
      expect(result.created_count).to eq 1
      expect(result.created.first.name).to eq "Widget"
    end
  end

  # ── Malformed CSV (illegal quoting) ──────────────────────────────────────
  describe "malformed CSV handling" do
    it "returns :malformed_csv instead of raising" do
      # A field that starts a quote but never closes it triggers Illegal quoting
      bad_csv = "Product Name,SKU\n\"unclosed,W-002\n"

      result = importer(bad_csv).call

      expect(result.ok?).to be false
      expect(result.header_error).to eq :malformed_csv
    end

    it "captures the offending line number and raw content" do
      bad_csv = "Product Name,SKU\nGood Widget,W-001\n\"unclosed,W-002\n"

      result = importer(bad_csv).call

      expect(result.parse_error).to be_a(described_class::ParseError)
      expect(result.parse_error.line_number).to be_a(Integer)
      expect(result.parse_error.raw_line).to be_a(String)
    end

    it "does not raise a 500-class exception" do
      bad_csv = "Product Name,SKU\n\"bad \"quoting\",W-003\n"

      expect { importer(bad_csv).call }.not_to raise_error
    end
  end

  # ── liberal_parsing: fields with embedded double-quotes ──────────────────
  describe "liberal quoting (Excel formula exports)" do
    it "handles a field that starts with a quote but is not properly closed" do
      # Excel sometimes exports =001 as ="001" which violates strict quoting
      csv = valid_csv([['Widget', '"=001"', '', '', '', '5.00', '0', '0', '0']])

      result = importer(csv).call

      expect(result.ok?).to be true
    end
  end

  # ── Invalid headers ───────────────────────────────────────────────────────
  describe "invalid headers" do
    it "returns :invalid_headers when required columns are missing" do
      csv = "Name,Code\nWidget,W-001\n"

      result = importer(csv).call

      expect(result.header_error).to eq :invalid_headers
      expect(result.ok?).to be false
    end
  end

  # ── Sample template matches current column schema ─────────────────────────
  describe ".sample_csv" do
    it "includes all expected headers for the non-variant architecture" do
      sample = described_class.sample_csv
      table  = CSV.parse(sample, headers: true)
      headers = table.headers.map(&:downcase)

      expect(headers).to include("product name", "sku", "barcode", "brand", "category",
                                  "initial cost", "current stock", "low stock level",
                                  "reorder quantity")
    end

    it "does not include variant columns" do
      sample = described_class.sample_csv
      expect(sample.downcase).not_to include("variant", "option", "parent")
    end

    it "has exactly one example data row" do
      sample = described_class.sample_csv
      table  = CSV.parse(sample, headers: true)
      expect(table.size).to eq 1
    end
  end

  # ── Normal import ─────────────────────────────────────────────────────────
  describe "successful import" do
    it "creates products and skips duplicates" do
      csv = valid_csv([
        ["Widget A", "WA-001", "111", "Acme", "Tools", "10.00", "0", "5", "10"],
        ["Widget A", "WA-001", "", "", "", "0", "0", "0", "0"]
      ])

      result = importer(csv).call

      expect(result.ok?).to be true
      expect(result.created_count).to eq 1
      expect(result.skipped_count).to eq 1
      expect(result.skipped.first.reason).to eq :duplicate_sku
    end
  end
end
