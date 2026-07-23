module Finance
  module BankStatements
    # Parses a single transaction-date value into a Date, regardless of where
    # it came from. Deliberately knows nothing about CSV or Excel — it accepts
    # whatever RowParser hands it (a String, or a Date/DateTime/Time object,
    # e.g. straight from a Roo Excel cell) and either returns a Date or raises
    # a fully-localized InvalidDateError. Both the CSV and XLSX import paths
    # go through RowParser, so both go through this same parser.
    #
    # Supports:
    #   - Date / DateTime / Time objects (Excel cells, already-parsed values)
    #   - Arabic month names, with common hamza/spelling variants
    #     (١٤ or 14) يوليو ٢٠٢٦ or 2026  → 2026-07-14
    #   - English month names: "14 July 2026", "14 Jul 2026"
    #   - Numeric formats: 2026-07-14, 14/07/2026, 14-07-2026, 2026/07/14,
    #     07/14/2026 (tried last — ambiguous with DD/MM/YYYY)
    #
    # Usage:
    #   Finance::BankStatements::DateParser.parse("14 يوليو 2026") # => #<Date: 2026-07-14>
    #   Finance::BankStatements::DateParser.parse("not a date")    # raises InvalidDateError
    class DateParser
      # Raised when no supported format matches. The message is already
      # localized via I18n (finance.bank_statements.row_errors.transaction_date_invalid)
      # — callers should show `#message` directly to the user. The original
      # raw value is kept on the exception (not translated/altered) so callers
      # can log it for debugging without exposing it as the user-facing text.
      class InvalidDateError < StandardError
        attr_reader :raw_value

        def initialize(raw_value)
          @raw_value = raw_value
          super(I18n.t("finance.bank_statements.row_errors.transaction_date_invalid", value: raw_value))
        end
      end

      BOM = "﻿"

      # أ/إ/آ → ا, ة → ه, ى → ي — same spelling-variant normalization used
      # for column headers, applied here to month names and separators.
      ARABIC_LETTER_NORMALIZATION = {
        "أ" => "ا", "إ" => "ا", "آ" => "ا",
        "ة" => "ه",
        "ى" => "ي"
      }.freeze

      ARABIC_DIGIT_NORMALIZATION = {
        "٠" => "0", "١" => "1", "٢" => "2", "٣" => "3", "٤" => "4",
        "٥" => "5", "٦" => "6", "٧" => "7", "٨" => "8", "٩" => "9"
      }.freeze

      # Keys are already run through ARABIC_LETTER_NORMALIZATION (e.g. أبريل
      # and ابريل both normalize to ابريل), so a single entry covers both
      # spellings listed in the requirements.
      ARABIC_MONTHS = {
        "يناير"  => 1,
        "فبراير" => 2,
        "مارس"   => 3,
        "ابريل"  => 4,
        "مايو"   => 5,
        "يونيو"  => 6,
        "يوليو"  => 7,
        "اغسطس"  => 8,
        "سبتمبر" => 9,
        "اكتوبر" => 10,
        "نوفمبر" => 11,
        "ديسمبر" => 12
      }.freeze

      ARABIC_MONTH_PATTERN = Regexp.union(ARABIC_MONTHS.keys).freeze

      ENGLISH_TEXTUAL_FORMATS = [
        "%d %B %Y",
        "%d %b %Y"
      ].freeze

      def self.parse(value)
        new(value).parse
      end

      def initialize(value)
        @raw = value
      end

      def parse
        return @raw if plain_date?(@raw)
        return @raw.to_date if @raw.respond_to?(:to_date) && (@raw.is_a?(DateTime) || @raw.is_a?(Time))

        str = normalize(@raw)
        raise InvalidDateError, @raw if str.blank?

        parse_arabic_month(str) ||
          parse_numeric(str) ||
          parse_english_month(str) ||
          raise(InvalidDateError, @raw)
      end

      private

      def plain_date?(value)
        value.is_a?(Date) && !value.is_a?(DateTime)
      end

      def normalize(value)
        s = value.to_s.delete(BOM).strip
        ARABIC_LETTER_NORMALIZATION.each { |from, to| s = s.gsub(from, to) }
        ARABIC_DIGIT_NORMALIZATION.each { |from, to| s = s.gsub(from, to) }
        s.gsub(/\s+/, " ").strip
      end

      def parse_arabic_month(str)
        match = str.match(/\A(\d{1,2})\s+(#{ARABIC_MONTH_PATTERN})\s+(\d{4})\z/)
        return nil unless match

        day, month_word, year = match[1].to_i, match[2], match[3].to_i
        safe_date(year, ARABIC_MONTHS.fetch(month_word), day)
      end

      # Explicit regex-driven parsing instead of Date.strptime trial-and-error:
      # strptime is lenient about unconsumed trailing digits, so trying
      # "%Y-%m-%d" against a DD-MM-YYYY string like "14-07-2026" doesn't raise
      # — it silently misreads it as year 0014, month 07, day 20 (the "26" is
      # discarded). Matching each shape with an anchored regex first, then
      # building the Date from named groups, makes that misparse impossible:
      # a 2-digit leading group can only ever be treated as a day.
      def parse_numeric(str)
        # ISO, 4-digit year first: 2026-07-14 or 2026/07/14
        if (m = str.match(%r{\A(\d{4})[-/](\d{1,2})[-/](\d{1,2})\z}))
          return safe_date(m[1].to_i, m[2].to_i, m[3].to_i)
        end

        # Day first with '-': 14-07-2026
        if (m = str.match(/\A(\d{1,2})-(\d{1,2})-(\d{4})\z/))
          return safe_date(m[3].to_i, m[2].to_i, m[1].to_i)
        end

        # Day first with '/': 14/07/2026 — DD/MM/YYYY is the primary reading;
        # only fall back to MM/DD/YYYY if that reading isn't a valid date.
        if (m = str.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z}))
          day, month, year = m[1].to_i, m[2].to_i, m[3].to_i
          safe_date(year, month, day) || safe_date(year, day, month)
        end
      end

      def parse_english_month(str)
        ENGLISH_TEXTUAL_FORMATS.each do |fmt|
          return Date.strptime(str, fmt)
        rescue ArgumentError, Date::Error
          next
        end
        nil
      end

      def safe_date(year, month, day)
        Date.new(year, month, day)
      rescue ArgumentError, Date::Error
        nil
      end
    end
  end
end
