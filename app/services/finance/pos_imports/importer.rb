module Finance
  module PosImports
    # Imports payment-provider transactions from an XLSX file. Re-derives
    # headers/mapping/validation/branch-resolution fresh from the stored file
    # via the shared Pipeline, rather than trusting persisted preview_data —
    # terminal mappings (and manually-ignored rows) could have changed since
    # the preview was generated (same rationale as
    # Finance::SalesImportsController#regenerate_preview).
    #
    # Two structural conditions abort the ENTIRE import before any DB write:
    # any Unknown Terminal ID, or any remaining row-level validation error
    # (one not yet fixed by re-upload or explicitly excluded via RowIgnorer).
    # Duplicate transaction_ids are the only normal, non-fatal outcome still
    # reported in the summary without aborting; a genuine failure (a DB
    # error, or ExpenseGenerator failing) rolls back the transaction —
    # "everything transactional" per the spec.
    class Importer
      include AuditLoggable

      BATCH_SIZE = 500

      Result = Struct.new(:ok, :pos_import, :error, keyword_init: true) { def ok? = ok }

      ExpenseGenerationFailed = Class.new(StandardError)

      def self.call(pos_import_id, actor:)
        new(pos_import_id, actor: actor).call
      end

      def initialize(pos_import_id, actor:)
        @pos_import_id = pos_import_id
        @actor         = actor
      end

      def call
        pos_import = PosImport.where(business: @actor.business).find(@pos_import_id)

        unless pos_import.pending? || pos_import.failed?
          return Result.new(ok: false, pos_import: pos_import,
                            error: "This file has already been imported")
        end

        pipeline = Pipeline.call(pos_import, business: @actor.business)

        if pipeline.resolution.unknown_terminals.any?
          terminal_ids = pipeline.resolution.unknown_terminals.map { |r| r[:terminal_id] }.uniq.join(", ")
          return Result.new(ok: false, pos_import: pos_import,
                            error: "Unknown Terminal ID(s): #{terminal_ids}. " \
                                   "Configure these Terminal IDs first, then retry the import.")
        end

        if pipeline.validation.invalid_rows.any?
          rows = pipeline.validation.invalid_rows.map { |r| r[:row_number] }.join(", ")
          return Result.new(ok: false, pos_import: pos_import,
                            error: "Row(s) #{rows} still have validation errors. Fix the file or ignore " \
                                   "each row before confirming.")
        end

        persist!(pos_import, pipeline)

        Result.new(ok: true, pos_import: pos_import)
      rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ExpenseGenerationFailed => e
        pos_import&.update_columns(status: "failed")
        Result.new(ok: false, pos_import: pos_import, error: e.message)
      end

      private

      def persist!(pos_import, pipeline)
        mapped       = pipeline.mapped
        status_split = pipeline.status_split
        validation   = pipeline.validation
        resolution   = pipeline.resolution

        now             = Time.current
        seen_ids        = existing_transaction_ids(resolution)
        duplicate_count = 0
        records         = []
        total_amount    = 0.to_d
        total_fees      = 0.to_d

        ActiveRecord::Base.transaction do
          resolution.resolved_rows.each do |row|
            attrs = row.attributes

            if seen_ids.include?(attrs[:transaction_id])
              duplicate_count += 1
              next
            end
            seen_ids << attrs[:transaction_id]

            amount     = attrs[:amount].to_s.to_d
            fees       = attrs[:fees].to_s.to_d
            admin_fees = attrs[:administrative_fees].to_s.to_d
            total_amount += amount
            total_fees   += fees + admin_fees

            records << {
              pos_import_id:        pos_import.id,
              business_id:          @actor.business_id,
              branch_id:            attrs[:branch_id],
              transaction_id:       attrs[:transaction_id],
              reference_number:     attrs[:reference_number],
              amount:               amount,
              payment_method:       attrs[:payment_method],
              status:               attrs[:status],
              transaction_date:     parse_time(attrs[:transaction_date]),
              provider_created_at:  parse_time(attrs[:provider_created_at]),
              terminal_id:          attrs[:terminal_id],
              fees:                 fees,
              administrative_fees:  admin_fees,
              created_at:           now,
              updated_at:           now
            }
          end

          records.each_slice(BATCH_SIZE) { |batch| PosTransaction.insert_all(batch) }

          invalidate_stale_bank_verifications!(records)

          ignored_amount = status_split.ignored_rows.sum { |row| row.attributes[:amount].to_s.to_d }

          pos_import.update!(
            total_rows:             mapped.size,
            imported_rows:          records.size,
            duplicate_rows:         duplicate_count,
            invalid_rows:           validation.invalid_rows.size,
            unknown_terminal_rows:  0,
            ignored_rows:           status_split.ignored_rows.size,
            ignored_amount:         ignored_amount,
            total_amount:           total_amount,
            total_fees:             total_fees,
            status:                 "imported"
          )

          expense_result = ExpenseGenerator.call(pos_import.id, actor: @actor)
          raise ExpenseGenerationFailed, expense_result.reason unless expense_result.ok?

          pos_import.update!(expenses_created_count: expense_result.expenses.size)

          log_audit(actor: @actor, auditable: pos_import, action: "pos_import_imported",
                    metadata: {
                      total_rows: mapped.size, imported_rows: records.size,
                      duplicate_rows: duplicate_count, invalid_rows: validation.invalid_rows.size,
                      ignored_rows: status_split.ignored_rows.size, ignored_amount: ignored_amount.to_s,
                      manually_ignored_rows: pos_import.pos_import_ignored_rows.count,
                      total_amount: total_amount.to_s, total_fees: total_fees.to_s,
                      expenses_created: expense_result.expenses.size
                    })
        end
      end

      # New POS rows can undermine bank matching that was already marked
      # "completed" against the old POS picture (see
      # DailyReconciliation#invalidate_bank_verification_for_pos_change! for
      # the actual invalidation — this just finds which DRs to check: the
      # (branch, calendar-date) buckets the newly inserted rows fall into,
      # same bucketing PosTransaction.for_calendar_date and
      # DailyReconciliationsController#build_pos_imported_dr_ids use).
      # Skipped rows (duplicates) never reach `records`, so a re-upload that
      # adds nothing new correctly triggers no invalidation.
      def invalidate_stale_bank_verifications!(records)
        return if records.empty?

        tz = @actor.business.timezone_object
        branch_dates = records.map { |r| [ r[:branch_id], r[:transaction_date].in_time_zone(tz).to_date ] }.uniq

        DailyReconciliation
          .where(business_id: @actor.business_id, branch_id: branch_dates.map(&:first).uniq,
                 business_date: branch_dates.map(&:last).uniq)
          .each do |dr|
            next unless branch_dates.include?([ dr.branch_id, dr.business_date ])

            dr.invalidate_bank_verification_for_pos_change!(actor: @actor)
          end
      end

      def existing_transaction_ids(resolution)
        incoming = resolution.resolved_rows.map { |row| row.attributes[:transaction_id] }.uniq
        return Set.new if incoming.empty?

        PosTransaction.where(business_id: @actor.business_id, transaction_id: incoming)
                      .pluck(:transaction_id).to_set
      end

      def parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      end
    end
  end
end
