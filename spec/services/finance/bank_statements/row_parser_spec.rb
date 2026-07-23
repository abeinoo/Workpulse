require "rails_helper"

RSpec.describe Finance::BankStatements::RowParser do
  let(:required_mapping) do
    {
      "transaction_date" => "Date",
      "amount"           => "Amount"
    }
  end

  let(:full_mapping) do
    required_mapping.merge(
      "reference_number" => "Ref",
      "description"      => "Description",
      "transaction_type" => "Type"
    )
  end

  def table_for(headers, rows)
    Finance::BankStatements::FileReader::Table.new(
      headers: headers,
      rows:    rows.map { |r| headers.zip(r).to_h }
    )
  end

  def valid_row = %w[2024-01-15 150.00].freeze

  # ── Parsing rows regardless of source format ─────────────────────────────── #

  describe "parsing a generic Table" do
    it "parses rows using the mapped columns" do
      table = table_for(
        %w[Date Amount Ref Description Type],
        [ [ "2024-01-15", "150.00", "REF-1", "Cash deposit", "Credit" ] ]
      )

      row = described_class.parse(table, column_mapping: full_mapping).valid_rows.first

      expect(row["transaction_date"]).to eq("2024-01-15")
      expect(row["amount"]).to eq("150.0")
      expect(row["reference_number"]).to eq("REF-1")
      expect(row["description"]).to eq("Cash deposit")
      expect(row["transaction_type"]).to eq("Credit")
    end

    it "works identically with Arabic headers (mapping is positional, not language-specific)" do
      arabic_headers = [ "تاريخ المعاملة", "المبلغ", "الوصف" ]
      table = table_for(arabic_headers, [ [ "2024-01-15", "150.00", "إيداع نقدي" ] ])
      mapping = {
        "transaction_date" => "تاريخ المعاملة",
        "amount"           => "المبلغ",
        "description"      => "الوصف"
      }

      row = described_class.parse(table, column_mapping: mapping).valid_rows.first
      expect(row["description"]).to eq("إيداع نقدي")
    end
  end

  # ── parse_row return-shape contract ────────────────────────────────────── #

  describe "parse_row return-shape contract" do
    it "always returns a Hash with string keys including 'errors' as an Array" do
      table  = table_for(%w[Date Amount], [ valid_row ])
      result = described_class.parse(table, column_mapping: required_mapping)

      result.valid_rows.each do |row|
        expect(row).to be_a(Hash)
        expect(row["errors"]).to be_an(Array)
        expect(row["valid"]).to eq(true)
      end
    end

    it "invalid rows also carry errors as an Array, never nil" do
      table  = table_for(%w[Date Amount], [ %w[2024-01-15 not-a-number] ])
      result = described_class.parse(table, column_mapping: required_mapping)

      result.invalid_rows.each do |row|
        expect(row).to be_a(Hash)
        expect(row["errors"]).to be_an(Array)
        expect(row["errors"]).not_to be_empty
        expect(row["valid"]).to eq(false)
      end
    end
  end

  # ── Optional columns left unmapped ───────────────────────────────────────── #

  describe "optional columns left unmapped" do
    it "parses successfully when optional fields are not mapped" do
      table  = table_for(%w[Date Amount], [ valid_row ])
      result = described_class.parse(table, column_mapping: required_mapping)

      expect(result.headers_valid?).to be(true)
      expect(result.valid_count).to eq(1)
      expect(result.invalid_count).to eq(0)
    end

    it "sets optional fields to nil when not mapped" do
      table = table_for(%w[Date Amount], [ valid_row ])
      row   = described_class.parse(table, column_mapping: required_mapping).valid_rows.first

      expect(row["reference_number"]).to be_nil
      expect(row["transaction_type"]).to be_nil
    end
  end

  # ── Validation rules ─────────────────────────────────────────────────────── #

  describe "required-field validation" do
    it "rejects a row with a blank transaction_date, using a localized message" do
      table = table_for(%w[Date Amount], [ [ "", "150.00" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(I18n.t("finance.bank_statements.row_errors.transaction_date_required"))
    end

    it "rejects a row with an unparseable date, using a localized message with the raw value" do
      table = table_for(%w[Date Amount], [ [ "not-a-date", "150.00" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(
        I18n.t("finance.bank_statements.row_errors.transaction_date_invalid", value: "not-a-date")
      )
    end

    it "never leaks a raw English exception string for an unparseable date" do
      table = table_for(%w[Date Amount], [ [ "not-a-date", "150.00" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).invalid_rows.first
      row["errors"].each { |message| expect(message).not_to match(/is not a recognised date format/) }
    end

    it "rejects a row with a non-numeric amount" do
      table = table_for(%w[Date Amount], [ [ "2024-01-15", "abc" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(
        I18n.t("finance.bank_statements.row_errors.amount_invalid", value: "abc")
      )
    end

    it "rejects a row with a zero amount" do
      table = table_for(%w[Date Amount], [ [ "2024-01-15", "0" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(I18n.t("finance.bank_statements.row_errors.amount_not_positive"))
    end

    it "returns a localized header_error when a required mapping column is missing" do
      bad_mapping = required_mapping.except("amount")
      table       = table_for(%w[Date Amount], [ valid_row ])
      result      = described_class.parse(table, column_mapping: bad_mapping)

      expect(result.headers_valid?).to be(false)
      expect(result.header_error).to eq(
        I18n.t("finance.bank_statements.errors.mapping_missing_fields", fields: I18n.t("finance.bank_statements.fields.amount"))
      )
    end
  end

  # ── Amount parsing ───────────────────────────────────────────────────────── #

  describe "amount parsing" do
    it "strips commas and whitespace from amount values" do
      table = table_for(%w[Date Amount], [ [ "2024-01-15", "1,234.50" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).valid_rows.first
      expect(row["amount"]).to eq("1234.5")
    end

    it "accepts integer-format amounts (as produced by Excel numeric cells)" do
      table = table_for(%w[Date Amount], [ [ "2024-01-15", "200" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).valid_rows.first
      expect(row["amount"]).to eq("200.0")
    end
  end

  # ── Date parsing ─────────────────────────────────────────────────────────── #

  describe "date parsing" do
    {
      "YYYY-MM-DD" => [ "2024-03-15", "2024-03-15" ],
      "DD/MM/YYYY" => [ "15/03/2024", "2024-03-15" ],
      "MM/DD/YYYY" => [ "03/15/2024", "2024-03-15" ],
      "DD-MM-YYYY" => [ "15-03-2024", "2024-03-15" ]
    }.each do |format_name, (date_str, expected)|
      it "parses #{format_name} format to the correct calendar date" do
        table = table_for(%w[Date Amount], [ [ date_str, "150.00" ] ])
        row   = described_class.parse(table, column_mapping: required_mapping).valid_rows.first
        expect(row["transaction_date"]).to eq(expected)
      end
    end

    it "parses an Arabic month-name date via DateParser" do
      table = table_for(%w[Date Amount], [ [ "14 يوليو 2026", "150.00" ] ])
      row   = described_class.parse(table, column_mapping: required_mapping).valid_rows.first
      expect(row["transaction_date"]).to eq("2026-07-14")
    end
  end

  # ── Mixed valid/invalid rows ─────────────────────────────────────────────── #

  describe "mixed valid and invalid rows" do
    let(:table) do
      table_for(%w[Date Amount], [
        valid_row,
        [ "2024-01-15", "bad" ],
        [ "", "150.00" ],
        [ "2024-01-15", "99.99" ]
      ])
    end

    subject(:result) { described_class.parse(table, column_mapping: required_mapping) }

    it "counts valid and invalid rows correctly" do
      expect(result.valid_count).to eq(2)
      expect(result.invalid_count).to eq(2)
      expect(result.total_rows).to eq(4)
    end
  end
end
