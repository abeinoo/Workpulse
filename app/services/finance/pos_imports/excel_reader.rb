require "roo"
require "roo-xls"

module Finance
  module PosImports
    # Reads an uploaded .xlsx payment-provider export into a raw grid — no
    # header assumption, unlike Finance::BankStatements::FileReader::ExcelReader,
    # because the real header row is not row 1 (see HeaderDetector). Deliberately
    # not shared with that reader: this is its own bounded context, matching how
    # Finance::SalesImports keeps its own independent file-parsing logic instead
    # of reusing Finance::BankStatements internals.
    class ExcelReader
      Error        = Class.new(StandardError)
      MalformedFile = Class.new(Error)

      RawGrid = Struct.new(:rows, keyword_init: true)

      def self.call(bytes, filename:)
        new(bytes, filename: filename).call
      end

      def initialize(bytes, filename:)
        @bytes    = bytes
        @filename = filename
      end

      def call
        extension = File.extname(@filename.to_s).delete_prefix(".").downcase

        Tempfile.create([ "pos_import", ".#{extension}" ], binmode: true) do |tmp|
          tmp.write(@bytes)
          tmp.flush

          spreadsheet = ::Roo::Spreadsheet.open(tmp.path, extension: extension.to_sym)
          build_grid(spreadsheet.sheet(spreadsheet.sheets.first))
        end
      rescue ::Roo::Error, ::Zip::Error, ::Ole::Storage::FormatError, ArgumentError => e
        raise MalformedFile, "The Excel file could not be read: #{e.message}"
      end

      private

      def build_grid(sheet)
        first_row = sheet.first_row
        last_row  = sheet.last_row
        return RawGrid.new(rows: []) if first_row.nil?

        rows = (first_row..(last_row || first_row)).map do |i|
          sheet.row(i).map { |cell| cell_to_s(cell) }
        end

        RawGrid.new(rows: rows)
      end

      # NOTE: DateTime < Date in Ruby, so DateTime must be checked (and
      # formatted WITH its time-of-day) before the plain-Date branch — a
      # `when Date, DateTime` ordering here previously matched every
      # DateTime cell against the date-only branch and silently discarded
      # its time. That's exactly the cell type Roo returns for "Paid At"-
      # style full-datetime XLSX cells (Roo::Excelx::Cell::DateTime#value
      # returns a DateTime, not a Time), so a "Paid At" formatted as a
      # datetime cell in the source file was previously truncated to
      # midnight — corrupting both the displayed transaction time AND,
      # whenever business_day_start_hour > 0, which business day the
      # transaction was even attributed to (midnight can roll back into the
      # PREVIOUS business day, silently excluding the row from this day's
      # POS Transaction Verification total).
      def cell_to_s(value)
        case value
        when nil
          ""
        when DateTime, Time
          value.strftime("%Y-%m-%d %H:%M:%S")
        when Date
          value.strftime("%Y-%m-%d")
        when Float
          value == value.to_i ? value.to_i.to_s : value.to_s
        else
          value.to_s.strip
        end
      end
    end
  end
end
