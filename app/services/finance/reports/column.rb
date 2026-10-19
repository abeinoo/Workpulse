module Finance
  module Reports
    # One column of a report Table (see table.rb). `money` columns are
    # right-aligned + currency in the view; CsvExporter emits them as plain numbers.
    #
    # Lives in its own file so Zeitwerk can autoload Finance::Reports::Column
    # even when it is referenced before Finance::Reports::Table.
    Column = Struct.new(:key, :label, :money, keyword_init: true)
  end
end
