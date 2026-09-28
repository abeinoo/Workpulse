require "rails_helper"

RSpec.describe Inventory::Imports::CsvColumnMapper do
  let(:fields) { Inventory::Imports::StockIssueImporter::COLUMNS }

  # The real stock-order export the feature was built for.
  let(:real_headers) do
    [ "Location", "Supplier", "Stock order ref", "Status", "Created", "Expected", "Product ID",
      "Product name", "Barcode", "SKU", "Qty ordered", "Qty received", "Product cost", "Total cost" ]
  end
  let(:real_csv) do
    CSV.generate do |csv|
      csv << real_headers
      csv << [ "Main", "Acme", "SO-1", "Received", "2026-09-01", "2026-09-02", "901", "أعواد خشبية كبيرة",
               "6281000000011", "UYN1", "2", "2", "35.00", "70.00" ]
      csv << [ "Main", "Acme, Inc.", "SO-1", "Received", "2026-09-01", "2026-09-02", "902", "Widget, large",
               "6281000000028", "ABC123", "5", "4", "10.00", "50.00" ]
    end
  end

  def mapper(csv) = described_class.new(csv, fields: fields)
  def idx(m, header) = m.headers.index(header)

  describe "#suggested_mapping" do
    it "maps the real export: SKU -> SKU, Quantity -> Qty ordered" do
      m = mapper(real_csv)
      expect(m.suggested_mapping).to eq("sku" => idx(m, "SKU"), "quantity" => idx(m, "Qty ordered"))
    end

    it "never suggests a cost/total column, even when it is the only numeric-looking one" do
      m = mapper("Code,Product cost,Total cost\nA,1,2\n")
      expect(m.suggested_mapping["quantity"]).to be_nil
      expect(m.suggested_mapping["sku"]).to eq(0)
    end

    it "matches the standard template case-insensitively" do
      m = mapper("sku,QUANTITY\nA,1\n")
      expect(m.suggested_mapping).to eq("sku" => 0, "quantity" => 1)
    end

    it "matches Arabic headers" do
      m = mapper("رمز المنتج,الكمية\nUYN1,2\n")
      expect(m.suggested_mapping).to eq("sku" => 0, "quantity" => 1)
      expect(m.headers).to eq([ "رمز المنتج", "الكمية" ])
    end

    it "falls back to Barcode for SKU only when no SKU-like column exists" do
      expect(mapper("Barcode,Qty\n123,1\n").suggested_mapping["sku"]).to eq(0)
      m = mapper("Barcode,Item Code,Qty\n123,A,1\n")
      expect(m.suggested_mapping["sku"]).to eq(1)
    end

    it "leaves unrecognised columns unmapped" do
      expect(mapper("Item,Amount to take\nA,1\n").suggested_mapping).to eq("sku" => nil, "quantity" => nil)
    end
  end

  describe "parsing" do
    it "strips a UTF-8 BOM from the first header" do
      m = mapper("﻿SKU,Quantity\nA,1\n".b)
      expect(m.headers.first).to eq("SKU")
      expect(m.suggested_mapping["sku"]).to eq(0)
    end

    it "handles quoted values containing commas and preserves Arabic values" do
      m = mapper(real_csv)
      rows = m.rows(m.suggested_mapping)
      expect(rows.map { |r| [ r["sku"], r["quantity"] ] }).to eq([ %w[UYN1 2], %w[ABC123 5] ])
      expect(m.samples(idx(m, "Supplier"))).to eq([ "Acme", "Acme, Inc." ])
      expect(m.samples(idx(m, "Product name")).first).to eq("أعواد خشبية كبيرة")
    end

    it "numbers rows as the spreadsheet does (header = row 1) and skips fully blank lines" do
      m = mapper("SKU,Quantity\nA,1\n,\nB,2\n")
      expect(m.rows(m.suggested_mapping).map { |r| r[:row_number] }).to eq([ 2, 4 ])
      expect(m.data_row_count).to eq(2)
    end

    it "uses the first non-blank line as the header" do
      m = mapper("\n\nSKU,Quantity\nA,1\n")
      expect(m.headers).to eq(%w[SKU Quantity])
      expect(m.rows(m.suggested_mapping).first[:row_number]).to eq(4)
    end

    it "rejects non-UTF-8 input" do
      expect { mapper("SKU,Quantity\n\xFF\xFE,1\n".b) }
        .to raise_error(described_class::ParseError, "invalid_encoding")
    end

    it "rejects malformed CSV and empty files" do
      expect { mapper("SKU,Quantity\n\"unterminated,1\n") }.to raise_error(described_class::ParseError, "malformed")
      expect { mapper("") }.to raise_error(described_class::ParseError, "empty_file")
    end

    it "round-trips through the form payload unchanged" do
      m  = mapper(real_csv)
      m2 = described_class.from_payload(m.payload, fields: fields)
      expect(m2.headers).to eq(m.headers)
      expect(m2.rows(m.suggested_mapping)).to eq(m.rows(m.suggested_mapping))
    end

    it "rejects a tampered payload" do
      expect { described_class.from_payload("not base64!!", fields: fields) }
        .to raise_error(described_class::ParseError, "invalid_payload")
    end
  end

  describe "mapping validation" do
    let(:m) { mapper(real_csv) }

    it "requires SKU and Quantity" do
      expect(m.mapping_errors("sku" => nil, "quantity" => nil))
        .to contain_exactly([ "sku", :required_missing ], [ "quantity", :required_missing ])
      expect(m.mapping_valid?("sku" => idx(m, "SKU"), "quantity" => nil)).to be false
    end

    it "refuses the same column for two fields" do
      col = idx(m, "SKU")
      expect(m.mapping_errors("sku" => col, "quantity" => col))
        .to contain_exactly([ "sku", :duplicate_column ], [ "quantity", :duplicate_column ])
    end

    it "normalizes params: blank = ignore, out-of-range and unknown keys dropped" do
      expect(m.normalize_mapping("sku" => "9", "quantity" => "", "bogus" => "1"))
        .to eq("sku" => 9, "quantity" => nil)
      expect(m.normalize_mapping("sku" => "99", "quantity" => "-1")).to eq("sku" => nil, "quantity" => nil)
    end

    it "emits only the mapped fields — extra columns are ignored" do
      rows = m.rows("sku" => idx(m, "SKU"), "quantity" => idx(m, "Qty received"))
      expect(rows.first.keys).to contain_exactly(:row_number, "sku", "quantity")
      expect(rows.map { |r| r["quantity"] }).to eq(%w[2 4])
    end
  end
end
