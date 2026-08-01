module Finance
  module PosImports
    # Resolves each valid row's Branch via its Terminal ID — the ONLY source of
    # truth for branch assignment. Branch Name/ID columns from the provider
    # export are never read (see Mapper's FIELD_MAP, which excludes them
    # entirely) and are never trusted.
    #
    # unknown_terminals is a per-row list (not grouped by terminal_id) so the
    # preview can show every offending row's original Excel data — and so a
    # single bad row can be ignored on its own without affecting other rows
    # that share the same unconfigured terminal.
    class BranchResolver
      ResolvedRow = Struct.new(:row_number, :attributes, keyword_init: true)
      Resolution  = Struct.new(:resolved_rows, :unknown_terminals, keyword_init: true)

      def self.call(rows, business:)
        new(rows, business: business).call
      end

      def initialize(rows, business:)
        @rows     = rows
        @business = business
      end

      def call
        terminal_to_branch = PosTerminal.active.where(business: @business)
                                        .pluck(:terminal_id, :branch_id)
                                        .to_h { |terminal_id, branch_id| [ normalize(terminal_id), branch_id ] }

        resolved_rows      = []
        unknown_terminals  = []

        @rows.each do |row|
          terminal_id = normalize(row.attributes[:terminal_id])
          branch_id   = terminal_to_branch[terminal_id]

          if branch_id
            resolved_rows << ResolvedRow.new(row_number: row.row_number,
                                             attributes: row.attributes.merge(branch_id: branch_id))
          else
            unknown_terminals << {
              row_number:        row.row_number,
              terminal_id:       row.attributes[:terminal_id].to_s.strip,
              product_name:      row.attributes[:product_name],
              amount:            row.attributes[:amount].to_s.to_d,
              status:            row.attributes[:status],
              transaction_date:  row.attributes[:transaction_date],
              reference_number:  row.attributes[:reference_number]
            }
          end
        end

        Resolution.new(resolved_rows: resolved_rows, unknown_terminals: unknown_terminals)
      end

      private

      def normalize(terminal_id)
        terminal_id.to_s.strip
      end
    end
  end
end
