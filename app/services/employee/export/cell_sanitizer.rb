module Employee
  module Export
    # Spreadsheet formula-injection guard for text cells (OWASP "CSV Injection").
    # A text value that a spreadsheet would read as a formula — one starting with
    # =, +, - or @ (also after leading whitespace), or with a tab or carriage
    # return — is prefixed with a single quote so it stays text. Applied to text
    # values only: dates and amounts are written as typed values. In XLSX every
    # text cell is written as a string with formula escaping on, so this is only
    # needed for CSV; a CSV phone number such as +9665… therefore reads '+9665….
    module CellSanitizer
      module_function

      DANGEROUS = /\A(?:[\t\r]|\s*[=+\-@])/

      def text(value)
        return value unless value.is_a?(String) && value.match?(DANGEROUS)

        "'#{value}"
      end
    end
  end
end
