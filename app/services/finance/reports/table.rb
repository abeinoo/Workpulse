module Finance
  module Reports
    # Uniform result shape every finance report returns, so a single generic view
    # and one CSV exporter can render them all.
    #
    #   columns : ordered [Column]; `money` columns are right-aligned + currency
    #   rows    : array of hashes keyed by column.key (raw values — numbers/strings)
    #   totals  : optional hash {column_key => numeric} rendered as a footer row
    Column = Struct.new(:key, :label, :money, keyword_init: true)

    Table = Struct.new(:title, :columns, :rows, :totals, keyword_init: true) do
      def totals? = totals.present?
    end
  end
end
