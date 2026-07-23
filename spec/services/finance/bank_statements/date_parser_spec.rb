require "rails_helper"

RSpec.describe Finance::BankStatements::DateParser do
  describe "Arabic month-name dates" do
    it "parses 14 يوليو 2026" do
      expect(described_class.parse("14 يوليو 2026")).to eq(Date.new(2026, 7, 14))
    end

    it "parses 17 يوليو 2026" do
      expect(described_class.parse("17 يوليو 2026")).to eq(Date.new(2026, 7, 17))
    end

    it "parses 1 أغسطس 2026" do
      expect(described_class.parse("1 أغسطس 2026")).to eq(Date.new(2026, 8, 1))
    end

    it "parses 5 سبتمبر 2026" do
      expect(described_class.parse("5 سبتمبر 2026")).to eq(Date.new(2026, 9, 5))
    end

    it "parses every Arabic month name, including hamza/spelling variants" do
      {
        "يناير"  => 1, "فبراير" => 2, "مارس" => 3,
        "أبريل"  => 4, "ابريل"  => 4,
        "مايو"   => 5, "يونيو"  => 6, "يوليو"  => 7,
        "أغسطس"  => 8, "اغسطس"  => 8,
        "سبتمبر" => 9,
        "أكتوبر" => 10, "اكتوبر" => 10,
        "نوفمبر" => 11, "ديسمبر" => 12
      }.each do |month_name, month_number|
        result = described_class.parse("10 #{month_name} 2026")
        expect(result).to eq(Date.new(2026, month_number, 10)),
          "expected #{month_name.inspect} to parse as month #{month_number}, got #{result.inspect}"
      end
    end

    it "normalizes Arabic-Indic digits alongside the month name" do
      expect(described_class.parse("١٤ يوليو ٢٠٢٦")).to eq(Date.new(2026, 7, 14))
    end

    it "tolerates BOM, extra whitespace, and non-normalized letter variants" do
      expect(described_class.parse("﻿ 14  يوليو  2026 ")).to eq(Date.new(2026, 7, 14))
    end
  end

  describe "English month-name dates" do
    it "parses 14 July 2026" do
      expect(described_class.parse("14 July 2026")).to eq(Date.new(2026, 7, 14))
    end

    it "parses abbreviated month names" do
      expect(described_class.parse("14 Jul 2026")).to eq(Date.new(2026, 7, 14))
    end
  end

  describe "numeric formats" do
    it "parses 2026-07-14 (ISO)" do
      expect(described_class.parse("2026-07-14")).to eq(Date.new(2026, 7, 14))
    end

    it "parses 14/07/2026 (DD/MM/YYYY)" do
      expect(described_class.parse("14/07/2026")).to eq(Date.new(2026, 7, 14))
    end

    it "parses 14-07-2026 (DD-MM-YYYY)" do
      expect(described_class.parse("14-07-2026")).to eq(Date.new(2026, 7, 14))
    end

    it "parses 07/14/2026 (MM/DD/YYYY) when the day would be invalid as DD/MM" do
      expect(described_class.parse("07/14/2026")).to eq(Date.new(2026, 7, 14))
    end
  end

  describe "Excel Date / DateTime / Time objects" do
    it "returns a plain Roo Excel Date cell unchanged" do
      date = Date.new(2026, 7, 14)
      expect(described_class.parse(date)).to eq(date)
    end

    it "converts a DateTime object to a Date" do
      expect(described_class.parse(DateTime.new(2026, 7, 14, 13, 30))).to eq(Date.new(2026, 7, 14))
    end

    it "converts a Time object to a Date" do
      expect(described_class.parse(Time.new(2026, 7, 14, 13, 30))).to eq(Date.new(2026, 7, 14))
    end
  end

  describe "invalid dates" do
    it "raises InvalidDateError for unparseable text" do
      expect { described_class.parse("not-a-date") }.to raise_error(described_class::InvalidDateError)
    end

    it "raises InvalidDateError for a blank value" do
      expect { described_class.parse("") }.to raise_error(described_class::InvalidDateError)
      expect { described_class.parse(nil) }.to raise_error(described_class::InvalidDateError)
    end

    it "raises InvalidDateError for an out-of-range calendar date" do
      expect { described_class.parse("31 فبراير 2026") }.to raise_error(described_class::InvalidDateError)
    end

    it "carries the original raw value on the exception for logging, without altering it" do
      described_class.parse("not-a-date")
    rescue described_class::InvalidDateError => e
      expect(e.raw_value).to eq("not-a-date")
    end

    it "raises a localized error message (English)" do
      I18n.with_locale(:en) do
        expect { described_class.parse("not-a-date") }.to raise_error(
          described_class::InvalidDateError, "Unsupported date format: not-a-date"
        )
      end
    end

    it "raises a localized error message (Arabic)" do
      I18n.with_locale(:ar) do
        expect { described_class.parse("17 يوليو 2026 extra garbage") }.to raise_error(
          described_class::InvalidDateError, "صيغة التاريخ غير مدعومة: 17 يوليو 2026 extra garbage"
        )
      end
    end

    it "never lets a raw Ruby exception message reach the caller" do
      described_class.parse("not-a-date")
    rescue described_class::InvalidDateError => e
      expect(e.message).not_to match(/ArgumentError|invalid date/i)
    end
  end
end
