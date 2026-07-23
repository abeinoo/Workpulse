require "rails_helper"

RSpec.describe Finance::BankStatements::ColumnMatcher do
  describe ".normalize" do
    it "trims whitespace and collapses internal multiple spaces" do
      expect(described_class.normalize("  Transaction   Date  ")).to eq("transaction date")
    end

    it "removes a leading BOM" do
      expect(described_class.normalize("﻿Date")).to eq("date")
    end

    it "ignores case" do
      expect(described_class.normalize("AMOUNT")).to eq(described_class.normalize("amount"))
    end

    it "normalizes Arabic hamza variants (أ إ آ) to ا" do
      expect(described_class.normalize("أمر")).to eq(described_class.normalize("امر"))
      expect(described_class.normalize("إمر")).to eq(described_class.normalize("امر"))
      expect(described_class.normalize("آمر")).to eq(described_class.normalize("امر"))
    end

    it "normalizes ة to ه" do
      expect(described_class.normalize("تاريخ الحركة")).to eq(described_class.normalize("تاريخ الحركه"))
    end

    it "normalizes ى to ي" do
      expect(described_class.normalize("متى")).to eq(described_class.normalize("متي"))
    end

    it "removes punctuation" do
      expect(described_class.normalize("Ref No.")).to eq("ref no")
      expect(described_class.normalize("Amount!!")).to eq("amount")
      expect(described_class.normalize("تاريخ، الحركة")).to eq(described_class.normalize("تاريخ الحركة"))
    end
  end

  describe ".match — one field per column (core requirement)" do
    it "never assigns the same header to two different fields" do
      # A single ambiguous-looking header must only ever end up on one side
      # of the mapping, never duplicated across fields.
      headers = [ "تاريخ الحركة" ]
      result  = described_class.match(headers)

      assigned_headers = result.values
      expect(assigned_headers.uniq.size).to eq(assigned_headers.size)
      expect(result).to eq("transaction_date" => "تاريخ الحركة")
    end

    it "never assigns two headers to the same field" do
      headers = [ "المبلغ المدين", "المبلغ الدائن" ]
      result  = described_class.match(headers)

      expect(result.keys.uniq.size).to eq(result.keys.size)
      expect(result["amount"]).to be_present
      # Only one of the two debit/credit columns is auto-assigned; the other
      # is left for the user to map manually rather than guessed.
      expect(result.size).to eq(1)
    end
  end

  describe ".match — Arabic headers" do
    it "maps each Arabic header to its correct field" do
      headers = [ "تاريخ الحركة", "المبلغ", "رقم المرجع", "الوصف", "نوع الحركة" ]
      result  = described_class.match(headers)

      expect(result).to eq(
        "transaction_date" => "تاريخ الحركة",
        "amount"           => "المبلغ",
        "reference_number" => "رقم المرجع",
        "description"      => "الوصف",
        "transaction_type" => "نوع الحركة"
      )
    end

    it "matches Arabic synonym variants for the same field" do
      expect(described_class.match([ "تاريخ العملية" ])).to eq("transaction_date" => "تاريخ العملية")
      expect(described_class.match([ "تاريخ المعاملة" ])).to eq("transaction_date" => "تاريخ المعاملة")
      expect(described_class.match([ "القيمة" ])).to eq("amount" => "القيمة")
      expect(described_class.match([ "رقم العملية" ])).to eq("reference_number" => "رقم العملية")
      expect(described_class.match([ "البيان" ])).to eq("description" => "البيان")
      expect(described_class.match([ "التفاصيل" ])).to eq("description" => "التفاصيل")
      expect(described_class.match([ "نوع العملية" ])).to eq("transaction_type" => "نوع العملية")
    end

    it "matches regardless of hamza/ta-marbuta spelling variants" do
      # "الحركة" written with a plain ه instead of ة should still match.
      expect(described_class.match([ "تاريخ الحركه" ])).to eq("transaction_date" => "تاريخ الحركه")
    end
  end

  describe ".match — English headers" do
    it "maps each English header to its correct field" do
      headers = %w[Date Amount Reference Description Type]
      result  = described_class.match(headers)

      expect(result).to eq(
        "transaction_date" => "Date",
        "amount"           => "Amount",
        "reference_number" => "Reference",
        "description"      => "Description",
        "transaction_type" => "Type"
      )
    end

    it "matches English synonym variants for the same field" do
      expect(described_class.match([ "Transaction Date" ])).to eq("transaction_date" => "Transaction Date")
      expect(described_class.match([ "Posting Date" ])).to eq("transaction_date" => "Posting Date")
      expect(described_class.match([ "Value" ])).to eq("amount" => "Value")
      expect(described_class.match([ "Ref No" ])).to eq("reference_number" => "Ref No")
      expect(described_class.match([ "Details" ])).to eq("description" => "Details")
      expect(described_class.match([ "Transaction Type" ])).to eq("transaction_type" => "Transaction Type")
    end

    it "is case-insensitive" do
      expect(described_class.match([ "DATE", "AMOUNT" ])).to eq(
        "transaction_date" => "DATE",
        "amount"           => "AMOUNT"
      )
    end
  end

  describe ".match — mixed Arabic/English headers" do
    it "maps each header correctly regardless of language" do
      headers = [ "تاريخ الحركة", "Amount", "رقم المرجع", "Description", "نوع الحركة" ]
      result  = described_class.match(headers)

      expect(result).to eq(
        "transaction_date" => "تاريخ الحركة",
        "amount"           => "Amount",
        "reference_number" => "رقم المرجع",
        "description"      => "Description",
        "transaction_type" => "نوع الحركة"
      )
    end
  end

  describe ".match — duplicate-like / ambiguous headers" do
    it "assigns only one of several near-duplicate headers to the same field" do
      headers = [ "المبلغ", "القيمة", "Amount", "Value" ]
      result  = described_class.match(headers)

      expect(result.keys).to eq([ "amount" ])
      expect(headers).to include(result["amount"])
    end

    it "does not let a generic single-word synonym claim an unrelated, more specific header" do
      # "Value Date" is a settlement-date column in real bank exports, not an
      # amount column — the lone "Value"/"Date" token overlap must not clear
      # the confidence threshold and mis-map it.
      result = described_class.match([ "Value Date", "Amount" ])

      expect(result["amount"]).to eq("Amount")
      expect(result["transaction_date"]).to be_nil
      expect(result.values).not_to include("Value Date")
    end
  end

  describe ".match — missing / unmappable columns" do
    it "returns an empty mapping when no header matches any known field" do
      result = described_class.match([ "رقم الحساب", "Random Column", "Notes" ])
      expect(result).to eq({})
    end

    it "leaves fields with no confident match absent from the result rather than guessing" do
      result = described_class.match([ "Amount" ])
      expect(result.keys).to eq([ "amount" ])
      expect(result).not_to have_key("transaction_date")
      expect(result).not_to have_key("reference_number")
      expect(result).not_to have_key("description")
      expect(result).not_to have_key("transaction_type")
    end

    it "handles an empty header list" do
      expect(described_class.match([])).to eq({})
    end
  end

  describe ".match — robustness to formatting noise" do
    it "matches despite BOM, punctuation and extra whitespace" do
      result = described_class.match([ "﻿  Date:  ", "Amount!!" ])
      expect(result["transaction_date"]).to eq("﻿  Date:  ")
      expect(result["amount"]).to eq("Amount!!")
    end
  end
end
