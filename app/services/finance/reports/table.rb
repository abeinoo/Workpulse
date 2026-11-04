module Finance
  module Reports
    # Uniform result shape every finance report returns, so a single generic view
    # and one CSV exporter can render them all.
    #
    #   columns : ordered [Column] (column.rb); `money` columns are right-aligned + currency
    #   rows    : array of hashes keyed by column.key (raw values — numbers/strings)
    #   totals  : optional hash {column_key => numeric} rendered as a footer row
    #   unallocated : optional row hash (same keys as rows) of business-level costs
    #             attributed to no branch (floating employees) — rendered on its
    #             own line after the rows, never as a branch, and included once
    #             in totals
    Table = Struct.new(:title, :columns, :rows, :totals, :unallocated, keyword_init: true) do
      def totals?      = totals.present?
      def unallocated? = unallocated.present?
    end
  end
end
