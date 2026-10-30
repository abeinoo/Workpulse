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
                               .includes(deposit_matches: [ :till_deposit, :matched_by ])

    @page        = [ params.fetch(:page, 1).to_i, 1 ].max
    @total_count = @transactions.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @transactions = @transactions.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE)

    @stats = build_statement_stats(@statement)
  end

  def new
    @statement = BankStatement.new
    authorize @statement
    @branches = importable_branches
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

    # A branch of this business outside the importer's branch scope is refused
    # here (the form lists only importable branches); another business's branch
    # is refused by BankStatement's own validation (BUG-033).
    if branch_outside_scope?(@statement)
      @statement.errors.add(:branch_id, t("finance.bank_statements.errors.branch_outside_scope"))
      @branches = importable_branches
      return render :new, status: :unprocessable_entity
    end

    uploaded_file = params[:bank_statement][:file]

    unless uploaded_file.present?
      @statement.errors.add(:file, t("finance.bank_statements.errors.file_blank"))
      @branches = importable_branches
      return render :new, status: :unprocessable_entity
    end

    unless Finance::BankStatements::FileReader.supported?(uploaded_file.original_filename)
      @statement.errors.add(:file, t("finance.bank_statements.errors.unsupported_file_type"))
      @branches = importable_branches
      return render :new, status: :unprocessable_entity
    end

    raw_bytes = uploaded_file.read

    if raw_bytes.blank?
      @statement.errors.add(:file, t("finance.bank_statements.errors.file_empty"))
      @branches = importable_branches
      return render :new, status: :unprocessable_entity
    end

    begin
      table = Finance::BankStatements::FileReader.read(raw_bytes, filename: uploaded_file.original_filename)
    rescue Finance::BankStatements::FileReader::Error
      @statement.errors.add(:file, t("finance.bank_statements.errors.file_malformed"))
      @branches = importable_branches
      return render :new, status: :unprocessable_entity
    end

    if table.headers.empty?
      @statement.errors.add(:file, t("finance.bank_statements.errors.no_header_row"))
      @branches = importable_branches
      return render :new, status: :unprocessable_entity
    end

    if table.rows.empty?
      @statement.errors.add(:file, t("finance.bank_statements.errors.no_data_rows"))
      @branches = importable_branches
      return render :new, status: :unprocessable_entity
    end

    @detected_headers  = table.headers
    @statement.file_name = uploaded_file.original_filename

    if @statement.save
      @statement.file.attach(uploaded_file)

      overlapping = detect_overlapping_statements(@statement)
      if overlapping.any?
        flash[:warning] = t("finance.bank_statements.overlap_warning",
                             count: overlapping.count,
                             files: overlapping.map(&:file_name).join(", "))
      elsif !pos_transactions_imported_for?(@statement)
        flash[:warning] = t("finance.bank_statements.pos_not_imported_warning")
      end

      redirect_to edit_column_mapping_finance_bank_statement_path(@statement)
    else
      @branches = importable_branches
      render :new, status: :unprocessable_entity
    end
  end

  def edit_column_mapping
    @statement        = find_statement
    authorize @statement, :edit_column_mapping?
    # Always re-detect from the stored file — no session dependency.
    @detected_headers = read_statement_table(@statement).headers
    # Pre-fill an auto-detected mapping on first visit only — never overwrite
    # a mapping the user already saved (or is currently editing after a
    # validation error, where @statement.column_mapping carries the submitted
    # values).
    if @statement.column_mapping.blank?
      @statement.column_mapping = Finance::BankStatements::ColumnMatcher.match(@detected_headers)
    end
  end

  def update_column_mapping
    @statement = find_statement
    authorize @statement, :update_column_mapping?

    mapping = build_column_mapping(params[:column_mapping])

    if mapping["transaction_date"].blank? || mapping["amount"].blank?
      @statement.errors.add(:base, t("finance.bank_statements.errors.mapping_missing_required"))
      @statement.column_mapping = mapping
      @detected_headers = read_statement_table(@statement).headers
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    @statement.update!(column_mapping: mapping)

    table        = read_statement_table(@statement)
    parse_result = Finance::BankStatements::RowParser.parse(table, column_mapping: mapping)

    if parse_result.header_error.present?
      @statement.errors.add(:base, parse_result.header_error)
      @detected_headers = table.headers
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    @statement.update_column(:preview_data, build_preview(parse_result))

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

    result = Finance::DepositVerification::MatchingEngine.call(@statement.id, actor: current_user, rematch: true)

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

    result = Finance::BankStatements::Deleter.call(
      @statement.id,
      actor: current_user,
      notes: params[:deletion_notes].presence
    )

    if result.ok?
      redirect_to finance_bank_statements_path, notice: t("finance.bank_statements.deleted")
    else
      redirect_to finance_bank_statement_path(@statement), alert: result.error
    end
  end

  private

  # Reads the stored file through the format-agnostic FileReader — works
  # identically for CSV and Excel, keyed off the statement's saved file_name.
  def read_statement_table(statement)
    Finance::BankStatements::FileReader.read(statement.file.download, filename: statement.file_name)
  end

  # Re-builds preview from the stored file + column_mapping when preview_data is absent.
  def regenerate_preview(statement)
    table        = read_statement_table(statement)
    parse_result = Finance::BankStatements::RowParser.parse(table, column_mapping: statement.column_mapping)
    build_preview(parse_result)
  end

  def build_preview(parse_result)
    {
      "total_rows"    => parse_result.total_rows,
      "valid_count"   => parse_result.valid_count,
      "invalid_count" => parse_result.invalid_count,
      "sample_rows"   => parse_result.valid_rows.first(5).map { |r|
        r.slice("transaction_date", "amount", "reference_number", "description", "transaction_type")
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

    permitted = mapping_params.permit(Finance::BankStatements::RowParser::ALL_FIELDS)
    permitted.to_h.reject { |_k, v| v.blank? }
  end

  def branch_outside_scope?(statement)
    return false if statement.branch_id.blank?
    return false unless current_user.business.branches.exists?(statement.branch_id)

    !importable_branches.exists?(statement.branch_id)
  end

  # Active branches a statement may be imported for: the importer's configured
  # import_bank_statement branch scope (business → every branch; branch / area →
  # managed ones; unset → the hierarchy default), as filter_by_branch_scope
  # resolves branch-scopable permissions. The form lists exactly these.
  def importable_branches
    ids = BranchScope.new(current_user).for_scope(current_user.scope_for(:import_bank_statement))
    current_user.business.branches.active.where(id: ids).order(:name)
  end

  def detect_overlapping_statements(statement)
    current_user.business.bank_statements
                .where.not(id: statement.id)
                .where("statement_from <= ? AND statement_to >= ?",
                       statement.statement_to, statement.statement_from)
                .then { |s| statement.branch_id? ? s.where(branch_id: [ statement.branch_id, nil ]) : s }
                .limit(5)
  end

  # Non-blocking check backing the pos_not_imported_warning: bank statement
  # matching is most reliable once POS transactions are already in the
  # system (they're the source of truth for expected card-payment deposits),
  # so we warn rather than hard-block — some businesses' bank statements do
  # cover periods with no card sales at all (e.g. cash-only branches).
  def pos_transactions_imported_for?(statement)
    tz          = current_user.business.timezone_object
    range_start = tz.local(statement.statement_from.year, statement.statement_from.month, statement.statement_from.day)
    range_end   = tz.local(statement.statement_to.year, statement.statement_to.month, statement.statement_to.day) + 1.day

    scope = PosTransaction.where(business_id: current_user.business.id, transaction_date: range_start...range_end)
    scope = scope.where(branch_id: statement.branch_id) if statement.branch_id?
    scope.exists?
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
