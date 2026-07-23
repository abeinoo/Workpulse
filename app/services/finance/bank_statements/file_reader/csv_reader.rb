require "csv"

module Finance
  module BankStatements
    class FileReader
      # Reads a CSV file into a FileReader::Table. Handles UTF-8, UTF-8-with-BOM,
      # and common Windows/Arabic export encodings via FileReader.normalize_encoding.
      class CsvReader
        def initialize(bytes)
          @bytes = bytes
        end

        def read
          table = CSV.parse(
            FileReader.normalize_encoding(@bytes),
            headers:         true,
            skip_blanks:     true,
            liberal_parsing: true
          )

          headers = FileReader.dedupe_headers(table.headers.map { |h| FileReader.clean_header(h) })
          rows    = table.map { |row| headers.zip(row.fields).to_h }

          FileReader::Table.new(headers: headers, rows: rows)
        rescue CSV::MalformedCSVError => e
          raise FileReader::MalformedFile, "CSV is malformed: #{e.message}"
        end
      end
    end
  end
end
