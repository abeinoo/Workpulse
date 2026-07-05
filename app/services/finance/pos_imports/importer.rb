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
    #
    # Idempotency: rows with a non-NULL reference_number are deduplicated against
    # all pos_transactions for the same business. A single bulk query loads all
    # existing reference numbers up front; no per-row EXISTS check is performed.
    # The DB unique index on (business_id, reference_number) enforces correctness
    # at the storage layer regardless of the in-memory filter.
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

          # Collect the reference numbers present in this CSV, then query only
          # those against the DB. Memory and query cost stay proportional to the
          # uploaded file rather than the business's full transaction history.
          # Runs after delete_all so re-importing this file sees zero existing
          # refs for its own previous transactions.
          incoming_refs = result.valid_rows.filter_map { |r| r["reference_number"].presence }.uniq
          existing_refs = incoming_refs.any? ?
            PosTransaction
              .where(business_id: @actor.business_id, reference_number: incoming_refs)
              .pluck(:reference_number)
              .to_set :
            Set.new

          duplicate_count = 0
          records         = []

          result.valid_rows.each do |row|
            dr_id = match_result.dr_id_for(row)
            # Skip unmatched rows when the caller did not opt in.
            next if dr_id.nil? && !@skip_unmatched

            ref_num = row["reference_number"]
            if ref_num.present? && existing_refs.include?(ref_num)
              duplicate_count += 1
              next
            end

            records << {
              pos_import_id:           pos_import.id,
              business_id:             @actor.business_id,
              daily_reconciliation_id: dr_id,
              transaction_date:        row["transaction_date"],
              branch_name:             row["branch_name"],
              cashier_name:            row["cashier_name"],
              payment_method_name:     row["payment_method_name"],
              amount:                  BigDecimal(row["amount"]),
              reference_number:        ref_num,
              transaction_id:          row["transaction_id"],
              raw_data:                row["raw_data"].to_json,
              created_at:              now,
              updated_at:              now
            }
          end

          imported_dr_ids = records.filter_map { |r| r[:daily_reconciliation_id] }.uniq

          records.each_slice(BATCH_SIZE) do |batch|
            # insert_all (no bang) uses ON CONFLICT DO NOTHING — belt-and-suspenders
            # safety net on top of the Ruby-level duplicate filter above.
            PosTransaction.insert_all(batch)
          end

          pos_import.update!(
            total_rows:     result.total_rows,
            failed_rows:    result.invalid_count,
            matched_rows:   records.size,
            unmatched_rows: match_result.unmatched_count,
            duplicate_rows: duplicate_count,
            dr_count:       imported_dr_ids.size,
            status:         "imported"
          )

          log_audit(
            actor:     @actor,
            auditable: pos_import,
            action:    :pos_import_imported,
            metadata:  {
              file_name:      pos_import.file_name,
              total_rows:     result.total_rows,
              invalid_rows:   result.invalid_count,
              duplicate_rows: duplicate_count,
              imported_rows:  records.size,
              unmatched_rows: match_result.unmatched_count,
              dr_count:       imported_dr_ids.size
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
