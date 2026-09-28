require "csv"
require "roo"

module Inventory
  module Imports
    # Turns an uploaded import file into CSV text for CsvColumnMapper, so CSV
    # and Excel share ONE mapping/preview/import pipeline:
    #
    #   .csv  -> bytes passed through untouched (the mapper handles UTF-8/BOM)
    #   .xlsx -> first worksheet, every row, flattened to CSV text
    #
    # The format is decided by extension AND content (an .xlsx must be a ZIP
    # container), never by the browser-supplied content type. Excel cells are
    # read as stored VALUES only — formulas are never evaluated (a formula cell
    # yields its cached result, if the file has one). Anything else is refused.
    class SpreadsheetReader
      SUPPORTED_EXTENSIONS = %w[.csv .xlsx].freeze
      MAX_SIZE             = Attachable::DEFAULT_DOCUMENT_SIZE
      ZIP_SIGNATURE        = "PK\x03\x04".b.freeze

      # Raises CsvColumnMapper::ParseError with an i18n key
      # (inventory.imports.mapping.parse_errors.*) as its message.
      def self.to_csv(bytes, filename:)
        new(bytes, filename: filename).to_csv
      end

      def initialize(bytes, filename:)
        @bytes     = bytes.to_s.b
        @extension = File.extname(filename.to_s).downcase
      end

      def to_csv
        fail!("unsupported_format") unless SUPPORTED_EXTENSIONS.include?(@extension)
        fail!("file_too_large") if @bytes.bytesize > MAX_SIZE
        return @bytes if @extension == ".csv"

        fail!("malformed_xlsx") unless @bytes.start_with?(ZIP_SIGNATURE)
        xlsx_to_csv
      end

      private

      def xlsx_to_csv
        Tempfile.create([ "stock_issue_import", ".xlsx" ], binmode: true) do |tmp|
          tmp.write(@bytes)
          tmp.flush

          book  = ::Roo::Excelx.new(tmp.path)
          sheet = book.sheet(book.sheets.first)
          return "" if sheet.first_row.nil?

          CSV.generate do |csv|
            (sheet.first_row..sheet.last_row).each do |i|
              csv << sheet.row(i).map { |cell| cell_to_s(cell) }
            end
          end
        end
      rescue ::Roo::Error, ::Zip::Error, ArgumentError, Nokogiri::XML::SyntaxError, NoMethodError, TypeError
        fail!("malformed_xlsx")
      end

      # Whole-number floats (Excel stores every number as a float) lose the
      # ".0" so a SKU typed as 12345 reads "12345" and a quantity 2 reads "2".
      def cell_to_s(value)
        case value
        when nil then ""
        when Float then value == value.to_i ? value.to_i.to_s : value.to_s
        when DateTime, Time then value.strftime("%Y-%m-%d %H:%M:%S")
        when Date then value.strftime("%Y-%m-%d")
        else value.to_s.strip
        end
      end

      def fail!(key)
        raise CsvColumnMapper::ParseError, key
      end
    end
  end
end
