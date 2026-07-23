require "roo"
require "roo-xls"

module Finance
  module BankStatements
    class FileReader
      # Reads an Excel file (.xlsx or .xls) into a FileReader::Table using Roo.
      # Always reads the first worksheet. Roo returns typed cell values (Date,
      # Float, String) based on each cell's format, so dates and numbers survive
      # the round trip instead of being read as raw serial numbers or strings.
      #
      # `roo`/`roo-xls` are already loaded via Bundler.require(*Rails.groups) in
      # config/application.rb, but this file requires them explicitly anyway —
      # `require` is idempotent, and it makes this file's dependency on the gem
      # self-evident rather than implicit on boot order. All external gem
      # constants (Roo, Zip, Ole) are referenced with a leading `::` so Ruby's
      # constant lookup goes straight to the top level instead of first walking
      # the Finance::BankStatements::FileReader::ExcelReader lexical nesting —
      # see the class-level comment on why that walk can fail.
      class ExcelReader
        def initialize(bytes, filename:)
          @bytes    = bytes
          @filename = filename
        end

        def read
          extension = FileReader.extension_of(@filename)

          Tempfile.create([ "bank_statement", ".#{extension}" ], binmode: true) do |tmp|
            tmp.write(@bytes)
            tmp.flush

            spreadsheet = ::Roo::Spreadsheet.open(tmp.path, extension: extension.to_sym)
            build_table(spreadsheet.sheet(spreadsheet.sheets.first))
          end
        rescue ::Roo::Error, ::Zip::Error, ::Ole::Storage::FormatError, ArgumentError => e
          raise FileReader::MalformedFile, "The Excel file could not be read: #{e.message}"
        end

        private

        def build_table(sheet)
          first_row = sheet.first_row
          last_row  = sheet.last_row
          return FileReader::Table.new(headers: [], rows: []) if first_row.nil?

          headers = FileReader.dedupe_headers(sheet.row(first_row).map { |h| FileReader.clean_header(h) })

          rows = ((first_row + 1)..(last_row || first_row)).filter_map do |i|
            values = sheet.row(i)
            next if values.compact.all? { |v| v.to_s.strip.empty? }

            headers.zip(values.map { |v| cell_to_s(v) }).to_h
          end

          FileReader::Table.new(headers: headers, rows: rows)
        end

        def cell_to_s(value)
          case value
          when nil
            ""
          when Date, DateTime
            value.strftime("%Y-%m-%d")
          when Time
            value.to_date.strftime("%Y-%m-%d")
          when Float
            value == value.to_i ? value.to_i.to_s : value.to_s
          else
            value.to_s.strip
          end
        end
      end
    end
  end
end
