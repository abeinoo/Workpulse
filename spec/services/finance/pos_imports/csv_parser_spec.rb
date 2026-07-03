require "rails_helper"

RSpec.describe Finance::PosImports::CsvParser do
  # Minimal valid column mapping (required fields only).
  let(:required_mapping) do
    {
      "transaction_date"    => "Date",
      "branch_name"         => "Branch",
      "cashier_name"        => "Cashier",
      "payment_method_name" => "Method",
      "amount"              => "Amount"
    }
  end

  # Mapping that also includes the optional columns.
  let(:full_mapping) do
    required_mapping.merge(
      "reference_number" => "Ref",
      "transaction_id"   => "TxnID"
    )
  end

  # Builds a minimal valid CSV string from the supplied rows hash.
  def make_csv(rows, headers: %w[Date Branch Cashier Method Amount])
    lines = [headers.join(",")]
    rows.each { |r| lines << headers.map { |h| r[h] }.join(",") }
    lines.join("\n")
  end

  VALID_ROW = {
    "Date"    => "2024-01-15",
    "Branch"  => "Main Branch",
    "Cashier" => "Ahmed",
    "Method"  => "Cash",
    "Amount"  => "150.00"
  }.freeze

  # ── parse_row return-shape contract ────────────────────────────────────── #

  describe "parse_row return-shape contract" do
    it "always returns a Hash with string keys including 'errors' as an Array" do
      csv   = make_csv([VALID_ROW])
      result = described_class.parse(csv, column_mapping: required_mapping)

      result.valid_rows.each do |row|
        expect(row).to be_a(Hash)
        expect(row["errors"]).to be_an(Array)
        expect(row["valid"]).to eq(true)
      end
    end

    it "invalid rows also carry errors as an Array, never nil" do
      bad_row = VALID_ROW.merge("Amount" => "not-a-number")
      csv     = make_csv([bad_row])
      result  = described_class.parse(csv, column_mapping: required_mapping)

      result.invalid_rows.each do |row|
        expect(row).to be_a(Hash)
        expect(row["errors"]).to be_an(Array)
        expect(row["errors"]).not_to be_empty
        expect(row["valid"]).to eq(false)
      end
    end

    it "every row (valid or invalid) has identical top-level keys" do
      mixed_csv = make_csv([VALID_ROW, VALID_ROW.merge("Amount" => "bad")])
      result    = described_class.parse(mixed_csv, column_mapping: required_mapping)

      all_rows = result.valid_rows + result.invalid_rows
      expect(all_rows.size).to eq(2)

      expected_keys = %w[row transaction_date branch_name cashier_name
                         payment_method_name amount reference_number
                         transaction_id raw_data valid errors]
      all_rows.each do |row|
        expect(row.keys).to match_array(expected_keys)
      end
    end
  end

  # ── Successful import with optional columns left unmapped ───────────────── #

  describe "optional columns left unmapped" do
    it "parses successfully when reference_number and transaction_id are not mapped" do
      csv    = make_csv([VALID_ROW])
      result = described_class.parse(csv, column_mapping: required_mapping)

      expect(result.headers_valid?).to be(true)
      expect(result.valid_count).to eq(1)
      expect(result.invalid_count).to eq(0)
    end

    it "sets optional fields to nil when not mapped" do
      csv  = make_csv([VALID_ROW])
      row  = described_class.parse(csv, column_mapping: required_mapping).valid_rows.first

      expect(row["reference_number"]).to be_nil
      expect(row["transaction_id"]).to be_nil
    end

    it "parses optional fields when they are mapped" do
      headers = %w[Date Branch Cashier Method Amount Ref TxnID]
      csv = [
        headers.join(","),
        "2024-01-15,Main Branch,Ahmed,Cash,150.00,REF-001,TXN-42"
      ].join("\n")

      row = described_class.parse(csv, column_mapping: full_mapping).valid_rows.first

      expect(row["reference_number"]).to eq("REF-001")
      expect(row["transaction_id"]).to eq("TXN-42")
    end

    it "a missing optional mapping never adds to errors" do
      csv = make_csv([VALID_ROW])
      row = described_class.parse(csv, column_mapping: required_mapping).valid_rows.first

      expect(row["errors"]).to be_empty
    end
  end

  # ── Validation rules ────────────────────────────────────────────────────── #

  describe "required-field validation" do
    it "rejects a row with a blank transaction_date" do
      csv  = make_csv([VALID_ROW.merge("Date" => "")])
      row  = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/transaction_date/))
    end

    it "rejects a row with an unparseable date" do
      csv = make_csv([VALID_ROW.merge("Date" => "not-a-date")])
      row = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/transaction_date/))
    end

    it "rejects a row with a blank branch_name" do
      csv = make_csv([VALID_ROW.merge("Branch" => "")])
      row = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/branch_name/))
    end

    it "rejects a row with a blank cashier_name" do
      csv = make_csv([VALID_ROW.merge("Cashier" => "")])
      row = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/cashier_name/))
    end

    it "rejects a row with a blank payment_method_name" do
      csv = make_csv([VALID_ROW.merge("Method" => "")])
      row = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/payment_method_name/))
    end

    it "rejects a row with a non-numeric amount" do
      csv = make_csv([VALID_ROW.merge("Amount" => "abc")])
      row = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/amount/))
    end

    it "rejects a row with a zero amount" do
      csv = make_csv([VALID_ROW.merge("Amount" => "0")])
      row = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/greater than zero/))
    end

    it "rejects a row with a negative amount" do
      csv = make_csv([VALID_ROW.merge("Amount" => "-5.00")])
      row = described_class.parse(csv, column_mapping: required_mapping).invalid_rows.first
      expect(row["errors"]).to include(match(/greater than zero/))
    end
  end

  describe "mapping-level validation" do
    it "returns a header_error when a required mapping column is missing" do
      bad_mapping = required_mapping.except("amount")
      result      = described_class.parse(make_csv([VALID_ROW]), column_mapping: bad_mapping)

      expect(result.headers_valid?).to be(false)
      expect(result.header_error).to match(/amount/)
    end
  end

  # ── Amount parsing ──────────────────────────────────────────────────────── #

  describe "amount parsing" do
    it "strips commas and whitespace from amount values" do
      # Comma inside the value must be quoted so the CSV parser sees it as one field.
      headers = %w[Date Branch Cashier Method Amount]
      csv = [
        headers.join(","),
        '2024-01-15,Main Branch,Ahmed,Cash,"1,234.50"'
      ].join("\n")
      row = described_class.parse(csv, column_mapping: required_mapping).valid_rows.first
      expect(row["amount"]).to eq("1234.5")
    end

    it "accepts integer-format amounts" do
      csv = make_csv([VALID_ROW.merge("Amount" => "200")])
      row = described_class.parse(csv, column_mapping: required_mapping).valid_rows.first
      expect(row["amount"]).to eq("200.0")
    end
  end

  # ── Date parsing ────────────────────────────────────────────────────────── #

  describe "date parsing" do
    {
      "YYYY-MM-DD" => "2024-03-15",
      "DD/MM/YYYY" => "15/03/2024",
      "MM/DD/YYYY" => "03/15/2024",
      "DD-MM-YYYY" => "15-03-2024"
    }.each do |format_name, date_str|
      it "parses #{format_name} format" do
        csv = make_csv([VALID_ROW.merge("Date" => date_str)])
        row = described_class.parse(csv, column_mapping: required_mapping).valid_rows.first
        expect(row["transaction_date"]).not_to be_nil
      end
    end
  end

  # ── Mixed valid/invalid rows ────────────────────────────────────────────── #

  describe "mixed valid and invalid rows" do
    let(:csv) do
      make_csv([
        VALID_ROW,
        VALID_ROW.merge("Amount" => "bad"),
        VALID_ROW.merge("Cashier" => ""),
        VALID_ROW.merge("Amount" => "99.99")
      ])
    end

    subject(:result) { described_class.parse(csv, column_mapping: required_mapping) }

    it "counts valid and invalid rows correctly" do
      expect(result.valid_count).to eq(2)
      expect(result.invalid_count).to eq(2)
      expect(result.total_rows).to eq(4)
    end

    it "every row in valid_rows has empty errors" do
      result.valid_rows.each do |row|
        expect(row["errors"]).to be_an(Array).and be_empty
        expect(row["valid"]).to be(true)
      end
    end

    it "every row in invalid_rows has non-empty errors" do
      result.invalid_rows.each do |row|
        expect(row["errors"]).to be_an(Array)
        expect(row["errors"]).not_to be_empty
        expect(row["valid"]).to be(false)
      end
    end
  end
end
