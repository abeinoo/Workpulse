require "rails_helper"
require "csv"

RSpec.describe "Employee export renderers" do
  field = Employee::Export::FieldCatalog::BY_KEY
  let(:fields) { [ field["full_name"], field["hire_date"], field["basic_salary"], field["notes"] ] }
  let(:rows) do
    [
      [ "سارة القحطاني", Date.new(2025, 7, 1), BigDecimal("12500.5"), "Line one\nline \"two\", three" ],
      [ "=1+1", nil, nil, "@SUM(A1)" ],
      [ "+966500000001", Date.new(2024, 12, 31), BigDecimal("-5"), "-2+3" ]
    ]
  end

  describe Employee::Export::CellSanitizer do
    it "prefixes text a spreadsheet would read as a formula" do
      [ "=1+1", "+1", "-1", "@A1", " =1", "\t=1", "\rx", "\tx" ].each do |value|
        expect(described_class.text(value)).to eq("'#{value}"), value.inspect
      end
    end

    it "leaves ordinary text, Arabic text and non-strings unchanged" do
      [ "Ali", "محمد", "a=b", "1-2", "", nil, 5, Date.new(2025, 1, 1) ].each do |value|
        expect(described_class.text(value)).to eq(value)
      end
    end
  end

  describe Employee::Export::CsvRenderer do
    subject(:csv) { described_class.render(fields, rows) }

    it "starts with a UTF-8 byte-order mark and is UTF-8" do
      expect(csv.bytes.first(3)).to eq([ 0xEF, 0xBB, 0xBF ])
      expect(csv.encoding).to eq(Encoding::UTF_8)
      expect(csv).to be_valid_encoding
    end

    it "quotes commas, quotes and line breaks so every value round-trips" do
      parsed = CSV.parse(csv.delete_prefix("﻿"))
      expect(parsed.size).to eq(4)
      expect(parsed[1]).to eq([ "سارة القحطاني", "2025-07-01", "12500.50", "Line one\nline \"two\", three" ])
    end

    it "neutralises formula injection in text cells but writes amounts as plain numbers" do
      parsed = CSV.parse(csv.delete_prefix("﻿"))
      expect(parsed[2]).to eq([ "'=1+1", nil, nil, "'@SUM(A1)" ])
      expect(parsed[3]).to eq([ "'+966500000001", "2024-12-31", "-5.00", "'-2+3" ])
    end

    it "uses the field labels as headers" do
      header = CSV.parse_line(csv.delete_prefix("﻿"))
      expect(header).to eq(fields.map(&:label))
    end
  end

  describe Employee::Export::XlsxRenderer do
    def workbook(data)
      file = Tempfile.new([ "employees", ".xlsx" ], binmode: true)
      file.write(data)
      file.flush
      Roo::Excelx.new(file.path)
    end

    it "writes typed cells: text as text (never a formula), dates as dates, amounts as numbers" do
      sheet = workbook(described_class.render(fields, rows))

      expect(sheet.row(1)).to eq(fields.map(&:label))
      expect(sheet.cell(2, 1)).to eq("سارة القحطاني")
      expect(sheet.cell(2, 2)).to eq(Date.new(2025, 7, 1))
      expect(sheet.celltype(2, 3)).to eq(:float)
      expect(sheet.cell(2, 3)).to eq(12_500.5)
      expect(sheet.cell(2, 4)).to eq("Line one\nline \"two\", three")

      expect(sheet.cell(3, 1)).to eq("=1+1")
      expect(sheet.formula(3, 1)).to be_nil
      expect(sheet.formula(3, 4)).to be_nil
      expect(sheet.cell(4, 1)).to eq("+966500000001")
      expect(sheet.cell(3, 2)).to be_nil
    end

    it "reads right to left in Arabic" do
      data = I18n.with_locale(:ar) { described_class.render(fields, rows) }
      sheet_xml = Zip::File.open_buffer(StringIO.new(data)).read("xl/worksheets/sheet1.xml")
      expect(sheet_xml).to include('rightToLeft="1"')
      english = Zip::File.open_buffer(StringIO.new(described_class.render(fields, rows))).read("xl/worksheets/sheet1.xml")
      expect(english).to include('rightToLeft="0"')
      expect(workbook(data).row(1)).to eq(I18n.with_locale(:ar) { fields.map(&:label) })
    end
  end
end
