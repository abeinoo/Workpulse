module Finance
  module PosImports
    # Imports POS transactions from a CSV, matches each row to its Daily
    # Reconciliation, and persists everything in batch.
    #
    # Accepts pos_import_id so the record is reloaded inside the service
    # (avoids inverse_of / autosave issues per the service architecture rules).
    #
    # When skip_unmatched: true, rows without a matching DR are silently dropped
    # and counted in pos_import.unmatched_rows. When false (default), the service
    # refuses to proceed if any unmatched rows exist.
    class Importer
      BATCH_SIZE = 500

      Result = Struct.new(:ok, :pos_import, :error, keyword_init: true) do
        def ok? = ok
      end

      def self.call(pos_import_id, actor:, skip_unmatched: false)
        new(pos_import_id, actor: actor, skip_unmatched: skip_unmatched).call
      end

      def initialize(pos_import_id, actor:, skip_unmatched:)
        @pos_import_id  = pos_import_id
        @actor          = actor
        @skip_unmatched = skip_unmatched
      end

      def call
        pos_import = PosImport.where(business: @actor.business).find(@pos_import_id)

        unless pos_import.pending? || pos_import.column_mapped? || pos_import.failed?
          return Result.new(ok: false, pos_import: pos_import,
                            error: "POS import has already been imported")
        end

        csv_data = pos_import.file.download
        result   = CsvParser.parse(csv_data, column_mapping: pos_import.column_mapping)
        return Result.new(ok: false, pos_import: pos_import, error: result.header_error) unless result.headers_valid?

        matcher      = DrMatcher.new(@actor.business)
        match_result = matcher.match(result.valid_rows)

        if match_result.unmatched_count > 0 && !@skip_unmatched
          return Result.new(ok: false, pos_import: pos_import,
                            error: "#{match_result.unmatched_count} transactions could not be matched to a Daily Reconciliation. Use skip_unmatched to proceed anyway.")
        end

        now = Time.current

        ActiveRecord::Base.transaction do
          # Clear previous transactions for this import (re-import support).
          pos_import.pos_transactions.delete_all

          # Build records array for batch insert.
          records = result.valid_rows.filter_map do |row|
            dr_id = match_result.dr_id_for(row)
            next if dr_id.nil? && !@skip_unmatched
            next if dr_id.nil? # skip_unmatched is true; drop this row

            {
              pos_import_id:          pos_import.id,
              business_id:            @actor.business_id,
              daily_reconciliation_id: dr_id,
              transaction_date:       row["transaction_date"],
              branch_name:            row["branch_name"],
              cashier_name:           row["cashier_name"],
              payment_method_name:    row["payment_method_name"],
              amount:                 BigDecimal(row["amount"]),
              reference_number:       row["reference_number"],
              transaction_id:         row["transaction_id"],
              raw_data:               row["raw_data"].to_json,
              created_at:             now,
              updated_at:             now
            }
          end

          # Also insert unmatched rows (daily_reconciliation_id: nil) when skipping.
          if @skip_unmatched
            unmatched_records = result.valid_rows.filter_map do |row|
              next unless match_result.dr_id_for(row).nil?
              {
                pos_import_id:          pos_import.id,
                business_id:            @actor.business_id,
                daily_reconciliation_id: nil,
                transaction_date:       row["transaction_date"],
                branch_name:            row["branch_name"],
                cashier_name:           row["cashier_name"],
                payment_method_name:    row["payment_method_name"],
                amount:                 BigDecimal(row["amount"]),
                reference_number:       row["reference_number"],
                transaction_id:         row["transaction_id"],
                raw_data:               row["raw_data"].to_json,
                created_at:             now,
                updated_at:             now
              }
            end
            records.concat(unmatched_records)
          end

          records.each_slice(BATCH_SIZE) do |batch|
            PosTransaction.insert_all!(batch)
          end

          pos_import.update!(
            total_rows:    result.total_rows,
            failed_rows:   result.invalid_count,
            matched_rows:  match_result.matched_count,
            unmatched_rows: match_result.unmatched_count,
            dr_count:      match_result.affected_dr_ids.size,
            status:        "imported"
          )

          log_audit(
            actor:     @actor,
            auditable: pos_import,
            action:    :pos_import_imported,
            metadata:  {
              file_name:      pos_import.file_name,
              total_rows:     result.total_rows,
              valid_rows:     result.valid_count,
              invalid_rows:   result.invalid_count,
              matched_rows:   match_result.matched_count,
              unmatched_rows: match_result.unmatched_count,
              dr_count:       match_result.affected_dr_ids.size
            }
          )
        end

        Result.new(ok: true, pos_import: pos_import, error: nil)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
        pos_import&.update_columns(status: "failed")
        Result.new(ok: false, pos_import: pos_import, error: e.message)
      end

      private

      include AuditLoggable
    end
  end
end
