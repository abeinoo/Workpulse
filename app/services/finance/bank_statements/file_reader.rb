module Finance
  module BankStatements
    # Single entry point for reading an uploaded bank statement file, regardless
    # of format. Detects the file type from its name and dispatches to the
    # matching adapter (CsvReader, ExcelReader). Every adapter returns the same
    # Table shape (headers + rows), so the column-mapping UI, RowParser, and
    # Importer work identically whether the source file is CSV or Excel.
    #
    # Adding a new format later (e.g. ODS) means adding one adapter class and
    # one branch in `read` — nothing downstream needs to change.
    class FileReader
      SUPPORTED_EXTENSIONS = %w[csv xlsx xls].freeze
      BOM = "﻿"

      Error               = Class.new(StandardError)
      UnsupportedFileType = Class.new(Error)
      MalformedFile       = Class.new(Error)

      Table = Struct.new(:headers, :rows, keyword_init: true) do
        def blank? = headers.empty?
      end

      def self.read(io, filename:)
        new(io, filename: filename).read
      end

      def self.supported?(filename)
        SUPPORTED_EXTENSIONS.include?(extension_of(filename))
      end

      def self.extension_of(filename)
        File.extname(filename.to_s).delete_prefix(".").downcase
      end

      # Converts raw bytes (typically ASCII-8BIT from Active Storage or file upload) to a
      # clean UTF-8 string and strips a leading BOM. `encode("UTF-8", undef: :replace)` on
      # an ASCII-8BIT string treats every byte > 0x7F as "undefined" and drops it, silently
      # erasing Arabic and other multi-byte content — so we reinterpret the bytes with
      # `force_encoding` first (they are UTF-8 already in the vast majority of cases), and
      # only fall back to a lossy transcode if that reinterpretation isn't valid UTF-8.
      def self.normalize_encoding(data)
        str = data.dup.force_encoding("UTF-8")
        str = str.valid_encoding? ? str : data.encode("UTF-8", "Windows-1256", invalid: :replace, undef: :replace, replace: "")
        str.sub(/\A#{BOM}/, "")
      rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
        data.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").sub(/\A#{BOM}/, "")
      end

      # Trims surrounding whitespace and BOM characters; never rewrites the header's
      # actual text (no translation, no transliteration).
      def self.clean_header(header)
        header.to_s.delete(BOM).strip
      end

      # Keeps duplicate header names distinguishable by suffixing repeats with
      # their occurrence count, e.g. two "Amount" columns become "Amount" and
      # "Amount (2)". Blank headers are given a positional placeholder so they
      # remain selectable in the mapping UI.
      def self.dedupe_headers(headers)
        seen = Hash.new(0)
        headers.each_with_index.map do |header, index|
          name = header.presence || "Column #{index + 1}"
          seen[name] += 1
          seen[name] == 1 ? name : "#{name} (#{seen[name]})"
        end
      end

      def initialize(io, filename:)
        @io       = io
        @filename = filename
      end

      def read
        case self.class.extension_of(@filename)
        when "csv"
          CsvReader.new(bytes).read
        when "xlsx", "xls"
          ExcelReader.new(bytes, filename: @filename).read
        else
          raise UnsupportedFileType, "Unsupported file type: #{@filename}"
        end
      end

      private

      def bytes
        @io.respond_to?(:read) ? @io.read : @io.to_s
      end
    end
  end
end
