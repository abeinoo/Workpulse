require "rails_helper"

RSpec.describe Inventory::Imports::SpreadsheetReader do
  let(:fields) { Inventory::Imports::StockIssueImporter::COLUMNS }

  def read(bytes, filename) = described_class.to_csv(bytes, filename: filename)
  def mapper_for(bytes, filename) = Inventory::Imports::CsvColumnMapper.from_upload(bytes, filename: filename, fields: fields)
  def parse_error(key) = raise_error(Inventory::Imports::CsvColumnMapper::ParseError, key)

  describe "CSV" do
    it "passes the bytes through unchanged (encoding/BOM handled by the mapper)" do
      bytes = "﻿كود الصنف,الكمية\nUYN1,2\n".b
      expect(read(bytes, "stock.CSV")).to eq(bytes)
    end
  end

  describe "XLSX" do
    it "flattens the first worksheet to CSV, whatever its name" do
      bytes = xlsx_bytes([ %w[SKU Quantity], [ "UYN1", 2 ] ], sheet_name: "My export")
      expect(CSV.parse(read(bytes, "stock.xlsx"))).to eq([ %w[SKU Quantity], %w[UYN1 2] ])
    end

    it "keeps Arabic headers/values and any column order, with extra columns intact" do
      bytes = xlsx_bytes([ [ "ملاحظات", "الكمية", "كود الصنف" ], [ "عاجل", 5, "ABC123" ] ])
      m = mapper_for(bytes, "arabic.xlsx")

      expect(m.headers).to eq([ "ملاحظات", "الكمية", "كود الصنف" ])
      expect(m.suggested_mapping).to eq("sku" => 2, "quantity" => 1)
      expect(m.rows(m.suggested_mapping)).to eq([ { :row_number => 2, "sku" => "ABC123", "quantity" => "5" } ])
    end

    it "handles blank cells, whole-number floats, decimals and text SKUs with leading zeros" do
      bytes = xlsx_bytes([ %w[SKU Quantity Note], [ "00123", 2.0, nil ], [ nil, 1.5, "x" ] ],
                         types: [ :string, :float, :string ])
      expect(CSV.parse(read(bytes, "t.xlsx"))).to eq([ %w[SKU Quantity Note], [ "00123", "2", "" ], [ "", "1.5", "x" ] ])
    end

    it "never evaluates formulas" do
      bytes = xlsx_bytes([ %w[SKU Quantity], [ "UYN1", "=1+1" ] ])
      quantity = CSV.parse(read(bytes, "f.xlsx")).last.last.to_s
      expect(quantity).not_to eq("2")
    end

    it "reports an empty workbook as an empty file" do
      expect { mapper_for(xlsx_bytes([]), "empty.xlsx") }.to parse_error("empty_file")
    end

    it "rejects a file that is not really an xlsx" do
      expect { read("SKU,Quantity\nA,1\n", "renamed.xlsx") }.to parse_error("malformed_xlsx")
      expect { read("PK\x03\x04garbage".b, "broken.xlsx") }.to parse_error("malformed_xlsx")
    end
  end

  describe "guards" do
    it "rejects unsupported extensions, including legacy .xls" do
      %w[stock.xls stock.txt stock stock.xlsx.exe].each do |name|
        expect { read("SKU,Quantity\n", name) }.to parse_error("unsupported_format")
      end
    end

    it "rejects files over the document size limit" do
      big = "a" * (Attachable::DEFAULT_DOCUMENT_SIZE + 1)
      expect { read(big, "big.csv") }.to parse_error("file_too_large")
    end
  end

  describe "templates" do
    it "ships an Excel template with the same SKU/Quantity columns as the CSV one" do
      xlsx = Inventory::Imports::StockIssueImporter.sample_xlsx
      csv  = Inventory::Imports::StockIssueImporter.sample_csv

      expect(CSV.parse(read(xlsx, "sample.xlsx"))).to eq(CSV.parse(csv))
    end
  end
end
