module Finance
  module PosImports
    # Builds the two summary shapes shown to the user: a pre-confirmation
    # preview (built from in-memory pipeline results, nothing persisted yet)
    # and a post-import summary (read straight off the persisted PosImport).
    class SummaryBuilder
      def self.for_preview(mapped_rows:, status_split:, validation:, resolution:, business:, pos_import: nil)
        new(business: business).build_preview(mapped_rows: mapped_rows, status_split: status_split,
                                              validation: validation, resolution: resolution,
                                              pos_import: pos_import)
      end

      def self.for_import(pos_import)
        new(business: pos_import.business).build_import_summary(pos_import)
      end

      def initialize(business:)
        @business = business
      end

      def build_preview(mapped_rows:, status_split:, validation:, resolution:, pos_import: nil, business: @business)
        branch_ids = resolution.resolved_rows.map { |row| row.attributes[:branch_id] }.uniq
        branches   = Branch.where(id: branch_ids).order(:name)

        fees_by_branch = resolution.resolved_rows.each_with_object(Hash.new(0.to_d)) do |row, totals|
          fees = row.attributes[:fees].to_s.to_d + row.attributes[:administrative_fees].to_s.to_d
          totals[row.attributes[:branch_id]] += fees
        end
        expenses_to_generate = fees_by_branch.filter_map do |branch_id, total|
          next if total <= 0

          branch = branches.find { |b| b.id == branch_id }
          { branch_name: branch&.name, total_fees: total }
        end

        # .as_json so this hash is safe to persist as-is into the jsonb
        # preview_data column and, when reloaded from the DB, comes back in
        # the exact same (string-keyed, primitive-valued) shape as when it
        # was freshly built — no AR objects, no symbol keys either way.
        {
          total_rows:            mapped_rows.size,
          valid_count:           validation.valid_rows.size,
          invalid_count:         validation.invalid_rows.size,
          ignored_count:         status_split.ignored_rows.size,
          ignored_amount:        status_split.ignored_rows.sum { |row| row.attributes[:amount].to_s.to_d },
          detected_branches:     branches.map(&:name),
          detected_terminal_ids: resolution.resolved_rows.map { |row| row.attributes[:terminal_id] }.uniq,
          unknown_terminals:     resolution.unknown_terminals,
          total_transactions:    resolution.resolved_rows.size,
          total_amount:          resolution.resolved_rows.sum { |row| row.attributes[:amount].to_s.to_d },
          total_fees:            fees_by_branch.values.sum,
          expenses_to_generate:  expenses_to_generate,
          validation_errors:     validation.invalid_rows,
          manually_ignored_rows: manually_ignored_rows_for(pos_import)
        }.as_json
      end

      def build_import_summary(pos_import)
        {
          total_rows:            pos_import.total_rows,
          imported_rows:         pos_import.imported_rows,
          duplicate_rows:        pos_import.duplicate_rows,
          invalid_rows:          pos_import.invalid_rows,
          unknown_terminal_rows: pos_import.unknown_terminal_rows,
          ignored_rows:          pos_import.ignored_rows,
          ignored_amount:        pos_import.ignored_amount,
          total_amount:          pos_import.total_amount,
          total_fees:            pos_import.total_fees,
          expenses_created:      pos_import.expenses_created_count,
          detected_branches:     Branch.where(id: pos_import.pos_transactions.distinct.pluck(:branch_id)).order(:name).pluck(:name),
          manually_ignored_rows: manually_ignored_rows_for(pos_import)
        }
      end

      private

      def manually_ignored_rows_for(pos_import)
        return [] if pos_import.nil? || !pos_import.persisted?

        pos_import.pos_import_ignored_rows.ordered.includes(:ignored_by).map do |row|
          {
            row_number:  row.row_number,
            reason:      row.reason,
            ignored_by:  row.ignored_by.full_name,
            ignored_at:  row.created_at
          }
        end
      end
    end
  end
end
