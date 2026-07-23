module Finance
  module BankStatements
    # Persists parsed rows (from a CSV or Excel file) as BankStatementTransaction records and then
    # triggers the MatchingEngine. Called after the user confirms the column
    # mapping.
    #
    # Accepts bank_statement_id so it can reload the record inside the service
    # (avoiding inverse_of / autosave issues per the service architecture rules).
    class Importer
      Result = Struct.new(:ok, :bank_statement, :error, keyword_init: true) do
        def ok? = ok
      end

      def self.call(bank_statement_id, actor:)
        new(bank_statement_id, actor: actor).call
      end

      def initialize(bank_statement_id, actor:)
        @bank_statement_id = bank_statement_id
        @actor             = actor
      end

      def call
        statement = BankStatement.where(business: @actor.business).find(@bank_statement_id)

        unless statement.pending? || statement.failed?
          return Result.new(ok: false, bank_statement: statement,
                            error: "Statement has already been imported")
        end

        table  = FileReader.read(statement.file.download, filename: statement.file_name)
        result = RowParser.parse(table, column_mapping: statement.column_mapping)

        return Result.new(ok: false, bank_statement: statement, error: result.header_error) unless result.headers_valid?

        statement.update!(status: "processing")

        ActiveRecord::Base.transaction do
          result.valid_rows.each do |row|
            BankStatementTransaction.create!(
              bank_statement:          statement,
              business:                @actor.business,
              transaction_date:        row["transaction_date"],
              amount:                  BigDecimal(row["amount"]),
              reference_number:        row["reference_number"],
              description:             row["description"],
              external_transaction_id: row["external_transaction_id"],
              transaction_type:        row["transaction_type"],
              raw_data:                row["raw_data"],
              status:                  "pending"
            )
          end

          statement.update!(
            total_rows:   result.total_rows,
            failed_rows:  result.invalid_count,
            status:       "completed"
          )

          log_audit(
            actor:     @actor,
            auditable: statement,
            action:    :bank_statement_imported,
            metadata:  {
              total_rows:   result.total_rows,
              valid_rows:   result.valid_count,
              invalid_rows: result.invalid_count
            }
          )
        end

        Finance::DepositVerification::MatchingEngine.call(statement.id, actor: @actor)

        Result.new(ok: true, bank_statement: statement, error: nil)
      rescue ActiveRecord::RecordInvalid, FileReader::Error => e
        statement&.update_columns(status: "failed")
        Result.new(ok: false, bank_statement: statement, error: e.message)
      end

      private

      include AuditLoggable
    end
  end
end
