require "csv"
require "base64"

module Inventory
  module Imports
    # Decouples a CSV import from the file's column names. Parses any UTF-8 CSV
    # (BOM tolerated, quoted fields/commas handled by the stdlib CSV parser),
    # exposes its headers, suggests which column feeds each importer field, and
    # turns a user-confirmed mapping into normalized rows:
    #
    #   [{ row_number: 2, "sku" => "UYN1", "quantity" => "2" }, ...]
    #
    # so an importer never reads raw headers. A mapping is { field_key => column
    # index (String/Integer) or blank for "ignore" } — indexes, not names, so
    # duplicate or blank header names stay unambiguous.
    #
    # `fields` is the importer's column schema: objects responding to #key,
    # #required and #synonyms (see StockIssueImporter::COLUMNS).
    class CsvColumnMapper
      class ParseError < StandardError; end

      BOM = "﻿".freeze

      # A column whose name contains any of these is a money/total column and
      # is never auto-suggested (e.g. "Product cost", "Total cost").
      EXCLUDED_WORDS = %w[cost price total amount value تكلفة التكلفة سعر السعر إجمالي الإجمالي قيمة القيمة].freeze

      attr_reader :headers

      # A fresh upload: CSV passes straight through, XLSX is flattened to CSV
      # text first (SpreadsheetReader), so both formats share everything below
      # — including #payload, which is therefore always CSV.
      def self.from_upload(bytes, filename:, fields:)
        new(SpreadsheetReader.to_csv(bytes, filename: filename), fields: fields)
      end

      # Rebuilds from #payload — the base64 copy of the file carried through
      # the mapping/preview round-trips as a hidden field.
      def self.from_payload(payload, fields:)
        data = begin
          Base64.strict_decode64(payload.to_s)
        rescue ArgumentError
          raise ParseError, "invalid_payload"
        end
        new(data, fields: fields)
      end

      # ParseError messages are i18n keys under inventory.imports.mapping.parse_errors.
      def initialize(csv_data, fields:)
        @fields = fields
        @text   = decode(csv_data)
        # Row numbers match what the user sees in a spreadsheet (first line =
        # row 1). The header is the first non-blank line; fully blank lines
        # (e.g. export padding) are never treated as data.
        numbered = parse(@text).each_with_index.map { |cells, i| [ i + 1, cells ] }
                               .reject { |_, cells| cells.all? { |c| c.to_s.strip.empty? } }
        raise ParseError, "empty_file" if numbered.empty?

        @headers = numbered.first.last.map { |h| h.to_s.strip }
        @data    = numbered.drop(1)
      end

      def payload
        Base64.strict_encode64(@text)
      end

      def data_row_count
        @data.size
      end

      # { field_key => column index or nil }. Exact synonym hits win over
      # partial matches, each column is suggested at most once, and money
      # columns are never suggested.
      def suggested_mapping
        taken = []
        @fields.to_h do |field|
          index = best_match(field, taken)
          taken << index if index
          [ field.key, index ]
        end
      end

      # Coerces raw params into { field_key => Integer index or nil }, dropping
      # unknown keys and out-of-range indexes.
      def normalize_mapping(raw)
        raw = raw.to_h.transform_keys(&:to_s)
        @fields.to_h do |field|
          value = raw[field.key].to_s
          index = value.match?(/\A\d+\z/) ? value.to_i : nil
          [ field.key, index && index < @headers.size ? index : nil ]
        end
      end

      # [[field_key, :required_missing | :duplicate_column], ...]
      def mapping_errors(mapping)
        errors = @fields.select { |f| f.required && mapping[f.key].nil? }
                        .map { |f| [ f.key, :required_missing ] }
        mapping.compact.group_by(&:last).each_value do |pairs|
          next if pairs.size < 2
          pairs.each { |key, _| errors << [ key, :duplicate_column ] }
        end
        errors
      end

      def mapping_valid?(mapping)
        mapping_errors(mapping).empty?
      end

      # Normalized rows for a valid mapping — the only shape importers consume.
      def rows(mapping)
        @data.map do |row_number, cells|
          mapping.each_with_object({ row_number: row_number }) do |(key, index), row|
            row[key] = index.nil? ? nil : cells[index].to_s.strip
          end
        end
      end

      # First few non-blank values in a column, to confirm a mapping at a glance.
      def samples(index, limit: 3)
        return [] if index.nil?

        @data.lazy.map { |_, cells| cells[index].to_s.strip }.reject(&:empty?).first(limit)
      end

      def self.normalize_header(name)
        name.to_s.unicode_normalize(:nfkc).downcase.gsub(/[\s_\-.:]+/, " ").strip
      end

      private

      def decode(data)
        text = data.to_s.dup.force_encoding(Encoding::UTF_8)
        raise ParseError, "invalid_encoding" unless text.valid_encoding?

        text.delete_prefix(BOM)
      end

      def parse(text)
        CSV.parse(text)
      rescue CSV::MalformedCSVError
        raise ParseError, "malformed"
      end

      def best_match(field, taken)
        candidates = @headers.each_with_index.reject do |name, index|
          taken.include?(index) || excluded?(name)
        end
        normalized = candidates.map { |name, index| [ self.class.normalize_header(name), index ] }
        synonyms   = field.synonyms.map { |s| self.class.normalize_header(s) }

        # 1. Exact synonym, in the schema's priority order.
        synonyms.each do |synonym|
          hit = normalized.find { |name, _| name == synonym }
          return hit.last if hit
        end

        # 2. A header containing a synonym as a whole word ("Variant SKU").
        synonyms.each do |synonym|
          hit = normalized.find { |name, _| name.split(" ").each_cons(synonym.split(" ").size).include?(synonym.split(" ")) }
          return hit.last if hit
        end

        # 3. Low-confidence fallbacks (e.g. Barcode for SKU) — only reached
        # when nothing better exists, and still editable by the user.
        fallbacks = field.respond_to?(:fallback_synonyms) ? Array(field.fallback_synonyms) : []
        fallbacks.map { |s| self.class.normalize_header(s) }.each do |synonym|
          hit = normalized.find { |name, _| name == synonym }
          return hit.last if hit
        end

        nil
      end

      def excluded?(name)
        words = self.class.normalize_header(name).split(" ")
        (words & EXCLUDED_WORDS).any?
      end
    end
  end
end
