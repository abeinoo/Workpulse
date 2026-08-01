module Finance
  module PosImports
    # Lets a user explicitly exclude a single row from a pending POS import —
    # with a mandatory reason and a full audit trail — instead of
    # re-uploading the whole file. Only a row Validator currently flags as
    # invalid, or a row currently blocked because its Terminal ID is
    # unconfigured, may be ignored this way — ignoring one row never affects
    # any other row that happens to share the same bad terminal, and never
    # touches file-level/structural problems (bad header, unparseable file),
    # which are rejected here even if a client tries to bypass the UI.
    class RowIgnorer
      include AuditLoggable

      Result = Struct.new(:ok, :pos_import, :ignored_row, :error, keyword_init: true) { def ok? = ok }

      def self.call(pos_import_id, row_number:, reason:, actor:)
        new(pos_import_id, row_number: row_number, reason: reason, actor: actor).call
      end

      def initialize(pos_import_id, row_number:, reason:, actor:)
        @pos_import_id = pos_import_id
        @row_number    = row_number.to_i
        @reason        = reason
        @actor         = actor
      end

      def call
        pos_import = PosImport.where(business: @actor.business).find(@pos_import_id)

        unless pos_import.pending? || pos_import.failed?
          return Result.new(ok: false, pos_import: pos_import, error: "This file has already been imported")
        end

        pipeline = Pipeline.call(pos_import, business: @actor.business)

        is_invalid_row     = pipeline.validation.invalid_rows.any? { |row| row[:row_number] == @row_number }
        is_unknown_terminal = pipeline.resolution.unknown_terminals.any? { |row| row[:row_number] == @row_number }

        unless is_invalid_row || is_unknown_terminal
          return Result.new(ok: false, pos_import: pos_import,
                            error: "Row #{@row_number} is not currently a validation error or an unknown-terminal " \
                                   "row and cannot be ignored.")
        end

        ignored_row = pos_import.pos_import_ignored_rows.create!(
          row_number: @row_number, reason: @reason, ignored_by: @actor
        )

        log_audit(actor: @actor, auditable: pos_import, action: "pos_import_row_ignored",
                  metadata: { row_number: @row_number, reason: @reason })

        Result.new(ok: true, pos_import: pos_import, ignored_row: ignored_row)
      rescue ActiveRecord::RecordInvalid => e
        Result.new(ok: false, pos_import: pos_import, error: e.record.errors.full_messages.to_sentence)
      end
    end
  end
end
