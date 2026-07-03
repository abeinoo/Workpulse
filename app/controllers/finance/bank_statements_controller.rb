class Finance::BankStatementsController < Finance::BaseController
  DEFAULT_PER_PAGE = 25

  def index
    authorize BankStatement
    @statements = policy_scope(BankStatement)
                    .then { |s| params[:status].present? ? s.where(status: params[:status]) : s }
                    .then { |s| params[:branch_id].present? ? s.where(branch_id: params[:branch_id]) : s }
                    .then { |s| params[:from].present? ? s.where("statement_from >= ?", params[:from]) : s }
                    .then { |s| params[:to].present? ? s.where("statement_to <= ?", params[:to]) : s }
                    .ordered
                    .includes(:branch, :imported_by)

    @page        = [ params.fetch(:page, 1).to_i, 1 ].max
    @total_count = @statements.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @statements  = @statements.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)
    @filter_branches = assignable_branches
  end

  def show
    @statement    = find_statement
    authorize @statement
    @transactions = @statement.bank_statement_transactions
                               .then { |s| params[:txn_status].present? ? s.where(status: params[:txn_status]) : s }
                               .ordered
                               .includes(:matched_till_deposit, :matched_by)

    @page        = [ params.fetch(:page, 1).to_i, 1 ].max
    @total_count = @transactions.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @transactions = @transactions.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)

    @stats = build_statement_stats(@statement)
  end

  def new
    @statement = BankStatement.new
    authorize @statement
    @branches = assignable_branches
  end

  def sample_csv
    authorize BankStatement, :new?
    csv = <<~CSV
      Transaction Date,Reference Number,Amount,Description
      2026-07-01,DEP1001,1000.00,Cash Deposit
      2026-07-01,DEP1002,500.00,Cash Deposit
      2026-07-02,DEP1003,250.00,Cash Deposit
    CSV
    send_data csv, filename: "bank_statement_sample.csv", type: "text/csv", disposition: "attachment"
  end

  def create
    @statement = current_user.business.bank_statements.build(create_params)
    @statement.imported_by = current_user
    authorize @statement

    unless params[:bank_statement][:file].present?
      @statement.errors.add(:file, t("finance.bank_statements.errors.file_blank"))
      @branches = assignable_branches
      return render :new, status: :unprocessable_entity
    end

    raw_bytes = params[:bank_statement][:file].read

    if raw_bytes.blank?
      @statement.errors.add(:file, t("finance.bank_statements.errors.file_empty"))
      @branches = assignable_branches
      return render :new, status: :unprocessable_entity
    end

    # Normalise to UTF-8; reject if the source encoding is fundamentally incompatible.
    begin
      csv_data = raw_bytes.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      @statement.errors.add(:file, t("finance.bank_statements.errors.unsupported_encoding"))
      @branches = assignable_branches
      return render :new, status: :unprocessable_entity
    end

    begin
      @detected_headers = Finance::BankStatements::CsvParser.detect_headers(csv_data)
    rescue ArgumentError => e
      key = e.message.include?("malformed") ? "finance.bank_statements.errors.csv_malformed"
                                             : "finance.bank_statements.errors.csv_no_header"
      @statement.errors.add(:file, t(key))
      @branches = assignable_branches
      return render :new, status: :unprocessable_entity
    end

    if @detected_headers.empty?
      @statement.errors.add(:file, t("finance.bank_statements.errors.csv_no_header"))
      @branches = assignable_branches
      return render :new, status: :unprocessable_entity
    end

    row_count = csv_data_row_count(csv_data)
    if row_count == 0
      @statement.errors.add(:file, t("finance.bank_statements.errors.no_data_rows"))
      @branches = assignable_branches
      return render :new, status: :unprocessable_entity
    end

    @statement.file_name = params[:bank_statement][:file].original_filename

    if @statement.save
      @statement.file.attach(params[:bank_statement][:file])

      overlapping = detect_overlapping_statements(@statement)
      if overlapping.any?
        flash[:warning] = t("finance.bank_statements.overlap_warning",
                             count: overlapping.count,
                             files: overlapping.map(&:file_name).join(", "))
      end

      redirect_to edit_column_mapping_finance_bank_statement_path(@statement)
    else
      @branches = assignable_branches
      render :new, status: :unprocessable_entity
    end
  end

  def edit_column_mapping
    @statement        = find_statement
    authorize @statement, :edit_column_mapping?
    # Always re-detect from the stored file — no session dependency.
    @detected_headers = Finance::BankStatements::CsvParser.detect_headers(@statement.file.download)
  end

  def update_column_mapping
    @statement = find_statement
    authorize @statement, :update_column_mapping?

    mapping = build_column_mapping(params[:column_mapping])

    if mapping["transaction_date"].blank? || mapping["amount"].blank?
      @statement.errors.add(:base, t("finance.bank_statements.errors.mapping_missing_required"))
      @detected_headers = Finance::BankStatements::CsvParser.detect_headers(@statement.file.download)
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    @statement.update!(column_mapping: mapping)

    csv_data     = @statement.file.download
    parse_result = Finance::BankStatements::CsvParser.parse(csv_data, column_mapping: mapping)

    if parse_result.header_error.present?
      @statement.errors.add(:base, parse_result.header_error)
      @detected_headers = Finance::BankStatements::CsvParser.detect_headers(csv_data)
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    # Persist preview data on the record — never in the cookie session.
    preview = {
      "total_rows"    => parse_result.total_rows,
      "valid_count"   => parse_result.valid_count,
      "invalid_count" => parse_result.invalid_count,
      "sample_rows"   => parse_result.valid_rows.first(5).map { |r|
        r.slice("transaction_date", "amount", "reference_number", "description")
      },
      "error_rows" => parse_result.invalid_rows.first(10).map { |r|
        r.slice("row", "transaction_date", "amount", "reference_number", "errors")
      }
    }
    @statement.update_column(:preview_data, preview)

    redirect_to preview_import_finance_bank_statement_path(@statement)
  end

  def preview_import
    @statement = find_statement
    authorize @statement, :update_column_mapping?
    @preview = @statement.preview_data.presence || regenerate_preview(@statement)
  end

  def confirm_import
    @statement = find_statement
    authorize @statement, :update_column_mapping?

    result = Finance::BankStatements::Importer.call(@statement.id, actor: current_user)

    if result.ok?
      redirect_to finance_bank_statement_path(@statement),
                  notice: t("finance.bank_statements.imported", count: result.bank_statement.total_rows)
    else
      redirect_to edit_column_mapping_finance_bank_statement_path(@statement),
                  alert: result.error
    end
  end

  def rematch
    @statement = find_statement
    authorize @statement, :rematch?

    result = Finance::BankStatements::MatchingEngine.call(@statement.id, actor: current_user, rematch: true)

    if result.ok?
      redirect_to finance_bank_statement_path(@statement),
                  notice: t("finance.bank_statements.rematched",
                             matched: result.matched, unmatched: result.unmatched)
    else
      redirect_to finance_bank_statement_path(@statement),
                  alert: result.error
    end
  end

  def destroy
    @statement = find_statement
    authorize @statement

    @statement.soft_destroy!(
      actor: current_user,
      notes: params[:deletion_notes].presence
    )
    redirect_to finance_bank_statements_path, notice: t("finance.bank_statements.deleted")
  rescue ActiveRecord::RecordNotDestroyed => e
    redirect_to finance_bank_statement_path(@statement), alert: e.message
  end

  private

  # Re-builds preview from the stored file + column_mapping when preview_data is absent.
  def regenerate_preview(statement)
    csv_data     = statement.file.download
    parse_result = Finance::BankStatements::CsvParser.parse(csv_data, column_mapping: statement.column_mapping)
    {
      "total_rows"    => parse_result.total_rows,
      "valid_count"   => parse_result.valid_count,
      "invalid_count" => parse_result.invalid_count,
      "sample_rows"   => parse_result.valid_rows.first(5).map { |r|
        r.slice("transaction_date", "amount", "reference_number", "description")
      },
      "error_rows" => parse_result.invalid_rows.first(10).map { |r|
        r.slice("row", "transaction_date", "amount", "reference_number", "errors")
      }
    }
  end

  def find_statement
    policy_scope(BankStatement).find(params[:id])
  end

  def create_params
    params.require(:bank_statement).permit(:branch_id, :statement_from, :statement_to, :notes)
  end

  def build_column_mapping(mapping_params)
    return {} unless mapping_params.respond_to?(:permit)

    permitted = mapping_params.permit(Finance::BankStatements::CsvParser::ALL_FIELDS)
    permitted.to_h.reject { |_k, v| v.blank? }
  end

  def csv_data_row_count(csv_data)
    require "csv"
    table = CSV.parse(
      csv_data.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""),
      headers: true, skip_blanks: true
    )
    table.count
  rescue CSV::MalformedCSVError
    0
  end

  def detect_overlapping_statements(statement)
    current_user.business.bank_statements
                .where.not(id: statement.id)
                .where("statement_from <= ? AND statement_to >= ?",
                       statement.statement_to, statement.statement_from)
                .then { |s| statement.branch_id? ? s.where(branch_id: [ statement.branch_id, nil ]) : s }
                .limit(5)
  end

  def build_statement_stats(statement)
    counts           = statement.bank_statement_transactions.group(:status).count
    total            = counts.values.sum
    ignored          = counts["ignored"].to_i
    needs_reverif    = counts["needs_reverification"].to_i
    denominator      = total - ignored
    {
      total:                 total,
      verified:              counts["verified"].to_i,
      amount_mismatch:       counts["amount_mismatch"].to_i,
      date_mismatch:         counts["date_mismatch"].to_i,
      unexpected:            counts["unexpected"].to_i,
      ignored:               ignored,
      needs_reverification:  needs_reverif,
      pending:               counts["pending"].to_i,
      rate:                  denominator.zero? ? 0 : (counts["verified"].to_i.to_f / denominator * 100).round(1)
    }
  end
end
