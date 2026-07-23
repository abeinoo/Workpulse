require "rails_helper"

RSpec.describe Finance::BankStatements::FileReader do
  def fixture_bytes(name)
    File.binread(Rails.root.join("spec/fixtures/files/#{name}"))
  end

  # ── Gem wiring ───────────────────────────────────────────────────────────── #
  #
  # Regression guard for two prior incidents:
  #   1. "cannot load such file -- roo" (LoadError) — roo/roo-xls missing from
  #      the installed gem set. ExcelReader now requires both explicitly.
  #   2. "uninitialized constant ...ExcelReader::Roo" (NameError) — referencing
  #      `Roo::Spreadsheet` unqualified inside the deeply-nested
  #      Finance::BankStatements::FileReader::ExcelReader class made Ruby walk
  #      the lexical Module.nesting (ExcelReader, FileReader, BankStatements,
  #      Finance) before falling back to the top level. ExcelReader now uses
  #      `::Roo`, `::Zip`, `::Ole` everywhere to bypass that walk entirely.
  describe "Roo gem availability" do
    it "is required and defined" do
      expect(defined?(Roo::Spreadsheet)).to be_truthy
    end

    it "registers both .xlsx and .xls (via roo-xls) extensions" do
      expect(Roo::CLASS_FOR_EXTENSION.keys).to include(:xlsx, :xls)
    end

    it "resolves from the top-level namespace the same way ExcelReader does internally" do
      expect(::Roo::Spreadsheet).to eq(Roo::Spreadsheet)
      expect(::Roo::Error).to eq(Roo::Error)
    end
  end

  # ── Format detection ─────────────────────────────────────────────────────── #

  describe ".supported?" do
    it "accepts .csv, .xlsx and .xls" do
      expect(described_class.supported?("statement.csv")).to be(true)
      expect(described_class.supported?("statement.xlsx")).to be(true)
      expect(described_class.supported?("statement.xls")).to be(true)
    end

    it "is case-insensitive on extension" do
      expect(described_class.supported?("STATEMENT.CSV")).to be(true)
      expect(described_class.supported?("Statement.XLSX")).to be(true)
    end

    it "rejects unsupported extensions" do
      expect(described_class.supported?("statement.pdf")).to be(false)
      expect(described_class.supported?("statement.txt")).to be(false)
      expect(described_class.supported?("statement")).to be(false)
    end
  end

  describe ".read" do
    it "raises UnsupportedFileType for an unsupported extension" do
      expect {
        described_class.read("some bytes", filename: "statement.pdf")
      }.to raise_error(described_class::UnsupportedFileType)
    end
  end

  # ── CSV: English ─────────────────────────────────────────────────────────── #

  describe "CSV — English headers" do
    it "reads headers and rows" do
      csv = "Transaction Date,Amount,Reference Number,Description\n2026-07-01,1000.00,DEP1001,Cash Deposit\n"
      table = described_class.read(csv, filename: "statement.csv")

      expect(table.headers).to eq(%w[Transaction\ Date Amount Reference\ Number Description])
      expect(table.rows.size).to eq(1)
      expect(table.rows.first["Description"]).to eq("Cash Deposit")
    end
  end

  # ── CSV: UTF-8 with BOM ──────────────────────────────────────────────────── #

  describe "CSV — UTF-8 with BOM" do
    it "strips the BOM from the first header" do
      table = described_class.read(fixture_bytes("bank_statement_english_bom.csv"), filename: "statement.csv")
      expect(table.headers.first).to eq("Transaction Date")
      expect(table.headers.first.bytes.first).not_to eq(0xEF)
    end
  end

  # ── CSV: Arabic headers/content ──────────────────────────────────────────── #

  describe "CSV — Arabic headers and content" do
    it "reads Arabic headers and content verbatim" do
      table = described_class.read(fixture_bytes("bank_statement_arabic.csv"), filename: "statement.csv")

      expect(table.headers).to eq([ "تاريخ المعاملة", "المبلغ", "رقم المرجع", "الوصف" ])
      expect(table.rows.first["الوصف"]).to eq("إيداع نقدي")
    end

    it "does not mangle Arabic bytes when they arrive as ASCII-8BIT (typical for uploads)" do
      bytes = fixture_bytes("bank_statement_arabic.csv").dup.force_encoding("ASCII-8BIT")
      table = described_class.read(bytes, filename: "statement.csv")
      expect(table.rows.first["الوصف"]).to eq("إيداع نقدي")
    end
  end

  # ── CSV: malformed ───────────────────────────────────────────────────────── #

  describe "CSV — malformed file" do
    it "raises MalformedFile for unparseable CSV content" do
      bad_csv = %("unterminated quote,value\nrow2,value2)
      expect {
        described_class.read(bad_csv, filename: "statement.csv")
      }.to raise_error(described_class::MalformedFile)
    end
  end

  # ── Excel: .xlsx ─────────────────────────────────────────────────────────── #

  describe "Excel .xlsx — English" do
    it "reads the first worksheet's headers and rows, preserving types" do
      table = described_class.read(fixture_bytes("bank_statement_english.xlsx"), filename: "statement.xlsx")

      expect(table.headers).to eq([ "Transaction Date", "Amount", "Reference Number", "Description" ])
      expect(table.rows.size).to eq(2)

      row = table.rows.first
      expect(row["Transaction Date"]).to eq("2026-07-01") # Date cell -> ISO string, not a serial number
      expect(row["Amount"]).to eq("1000")                 # whole-number Float -> clean integer string
      expect(row["Description"]).to eq("Cash Deposit")
    end

    it "preserves non-integer amounts" do
      table = described_class.read(fixture_bytes("bank_statement_english.xlsx"), filename: "statement.xlsx")
      expect(table.rows.second["Amount"]).to eq("500.5")
    end
  end

  describe "Excel .xlsx — Arabic" do
    it "reads Arabic headers and content verbatim" do
      table = described_class.read(fixture_bytes("bank_statement_arabic.xlsx"), filename: "statement.xlsx")

      expect(table.headers).to eq([ "تاريخ المعاملة", "المبلغ", "رقم المرجع", "الوصف" ])
      expect(table.rows.first["الوصف"]).to eq("إيداع نقدي")
      expect(table.rows.first["تاريخ المعاملة"]).to eq("2026-07-01")
    end
  end

  describe "Excel .xlsx — duplicate headers" do
    it "keeps duplicate header names distinguishable" do
      table = described_class.read(fixture_bytes("bank_statement_duplicate_headers.xlsx"), filename: "statement.xlsx")
      expect(table.headers).to eq([ "Amount", "Amount (2)", "Description" ])
    end
  end

  # ── Excel: .xls (legacy binary format) ───────────────────────────────────── #

  describe "Excel .xls" do
    it "reads headers and rows via the roo-xls adapter" do
      table = described_class.read(fixture_bytes("bank_statement_english.xls"), filename: "statement.xls")

      expect(table.headers).to eq([ "Transaction Date", "Amount", "Reference Number", "Description" ])
      expect(table.rows.first["Reference Number"]).to eq("DEP1001")
    end

    it "reads Arabic .xls content" do
      table = described_class.read(fixture_bytes("bank_statement_arabic.xls"), filename: "statement.xls")
      expect(table.headers).to eq([ "تاريخ المعاملة", "المبلغ", "الوصف" ])
      expect(table.rows.first["الوصف"]).to eq("إيداع نقدي")
    end
  end

  # ── Excel: malformed ─────────────────────────────────────────────────────── #

  describe "Excel — malformed file" do
    it "raises MalformedFile for a corrupt .xlsx" do
      expect {
        described_class.read("not a real xlsx file", filename: "statement.xlsx")
      }.to raise_error(described_class::MalformedFile)
    end

    it "raises MalformedFile for a corrupt .xls" do
      expect {
        described_class.read("not a real xls file", filename: "statement.xls")
      }.to raise_error(described_class::MalformedFile)
    end
  end

  # ── CSV and Excel produce an identical Table shape ──────────────────────── #

  describe "format-agnostic Table shape" do
    it "returns the same headers/rows shape for CSV and Excel sources" do
      csv   = "Date,Amount\n2026-07-01,100.00\n"
      csv_table  = described_class.read(csv, filename: "s.csv")
      xlsx_table = described_class.read(fixture_bytes("bank_statement_english.xlsx"), filename: "s.xlsx")

      [ csv_table, xlsx_table ].each do |table|
        expect(table).to respond_to(:headers)
        expect(table).to respond_to(:rows)
        expect(table.rows.first).to be_a(Hash)
      end
    end
  end
end
