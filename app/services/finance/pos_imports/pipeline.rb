module Finance
  module PosImports
    # The single shared read pipeline: reads the stored file and runs it
    # through ExcelReader -> HeaderDetector -> Mapper -> StatusFilter ->
    # IgnoredRowsFilter -> Validator -> BranchResolver. Used by the preview
    # page, RowIgnorer (to confirm a row is currently a validation error
    # before letting it be ignored), and Importer (which never trusts
    # persisted preview_data and always re-derives from the file).
    #
    # Always reads pos_import.pos_import_ignored_rows fresh from the DB, so a
    # row ignored a moment ago is immediately excluded from every subsequent
    # call — including the one Importer makes at confirm time.
    class Pipeline
      Result = Struct.new(:mapped, :status_split, :ignored_split, :validation, :resolution, keyword_init: true)

      def self.call(pos_import, business:)
        new(pos_import, business: business).call
      end

      def initialize(pos_import, business:)
        @pos_import = pos_import
        @business   = business
      end

      def call
        grid      = ExcelReader.call(@pos_import.file.download, filename: @pos_import.file_name)
        header    = HeaderDetector.call(grid.rows)
        data_rows = grid.rows[(header.row_index + 1)..] || []
        mapped    = Mapper.call(headers: header.headers, data_rows: data_rows, starting_row: header.row_index + 2)

        status_split  = StatusFilter.call(mapped)
        ignored_split = IgnoredRowsFilter.call(status_split.included_rows, @pos_import.ignored_row_numbers)

        validation = Validator.call(ignored_split.included_rows)
        resolution = BranchResolver.call(validation.valid_rows, business: @business)

        Result.new(mapped: mapped, status_split: status_split, ignored_split: ignored_split,
                  validation: validation, resolution: resolution)
      end
    end
  end
end
