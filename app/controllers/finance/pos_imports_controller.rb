class Finance::PosImportsController < Finance::BaseController
  before_action :set_pos_import, only: %i[show preview_import confirm_import ignore_row destroy]

  ACCEPTED_EXTENSION = ".xlsx".freeze
  DEFAULT_PER_PAGE = 25

  SORT_COLUMNS = { "date" => "transaction_date", "amount" => "amount", "fee" => "fees" }.freeze

  # GET /finance/pos_imports
  def index
    authorize PosImport
    @imports = current_user.business.pos_imports
                          .includes(:imported_by)
                          .ordered
                          .limit(50)

    @back_to_daily_reconciliations_path = daily_reconciliations_return_path
  end

  # GET /finance/pos_imports/:id
  def show
    authorize @pos_import

    @transactions = @pos_import.pos_transactions
                       .then { |s| params[:transaction_id].present? ? s.where("transaction_id ILIKE ?", "%#{params[:transaction_id]}%") : s }
                       .then { |s| params[:reference_number].present? ? s.where("reference_number ILIKE ?", "%#{params[:reference_number]}%") : s }
                       .then { |s| params[:branch_id].present? ? s.where(branch_id: params[:branch_id]) : s }
                       .then { |s| params[:payment_method].present? ? s.where(payment_method: params[:payment_method]) : s }
                       .then { |s| params[:status].present? ? s.where(status: params[:status]) : s }
                       .then { |s| params[:date_from].present? ? s.where(transaction_date: parse_date(params[:date_from])..) : s }
                       .then { |s| params[:date_to].present? ? s.where(transaction_date: ..(parse_date(params[:date_to]) + 1.day)) : s }
                       .includes(:branch)
                       .order(Arel.sql("#{SORT_COLUMNS.fetch(params[:sort], "transaction_date")} #{params[:direction] == "asc" ? "asc" : "desc"}"))

    @page        = [ params.fetch(:page, 1).to_i, 1 ].max
    @total_count = @transactions.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @transactions = @transactions.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE).to_a

    @filter_branches        = @pos_import.pos_transactions.joins(:branch).distinct.pluck("branches.id", "branches.name").sort_by { |_, name| name }
    @filter_payment_methods = @pos_import.pos_transactions.distinct.pluck(:payment_method).compact.sort
    @filter_statuses        = @pos_import.pos_transactions.distinct.pluck(:status).compact.sort

    @daily_reconciliations_by_branch_and_date = daily_reconciliations_for(@transactions)
  end

  # GET /finance/pos_imports/new
  def new
    @pos_import = PosImport.new
    authorize @pos_import
  end

  # POST /finance/pos_imports
  def create
    @pos_import = current_user.business.pos_imports.build
    @pos_import.imported_by = current_user
    authorize @pos_import

    file = params.dig(:pos_import, :file)
    unless file.present?
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.file_blank"))
      return render :new, status: :unprocessable_entity
    end

    unless File.extname(file.original_filename.to_s).downcase == ACCEPTED_EXTENSION
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.invalid_extension"))
      return render :new, status: :unprocessable_entity
    end

    bytes = file.read
    if bytes.blank?
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.file_empty"))
      return render :new, status: :unprocessable_entity
    end

    @pos_import.file_name = file.original_filename

    unless @pos_import.save
      return render :new, status: :unprocessable_entity
    end

    @pos_import.file.attach(io: StringIO.new(bytes), filename: file.original_filename)

    begin
      @preview = build_preview(@pos_import)
    rescue Finance::PosImports::ExcelReader::MalformedFile
      @pos_import.destroy
      @pos_import = PosImport.new(file_name: file.original_filename)
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.malformed_file"))
      return render :new, status: :unprocessable_entity
    rescue Finance::PosImports::HeaderDetector::HeaderNotFoundError
      @pos_import.destroy
      @pos_import = PosImport.new(file_name: file.original_filename)
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.header_not_found"))
      return render :new, status: :unprocessable_entity
    rescue Finance::PosImports::Mapper::MissingRequiredColumnsError => e
      @pos_import.destroy
      @pos_import = PosImport.new(file_name: file.original_filename)
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.missing_required_columns", fields: e.message))
      return render :new, status: :unprocessable_entity
    end

    @pos_import.update_column(:preview_data, @preview)
    redirect_to preview_import_finance_pos_import_path(@pos_import)
  end

  # GET /finance/pos_imports/:id/preview_import
  def preview_import
    authorize @pos_import
    @preview = (@pos_import.preview_data.presence || regenerate_preview(@pos_import)).with_indifferent_access
  end

  # POST /finance/pos_imports/:id/ignore_row
  # Excludes a single row-level validation error from the pending import
  # (mandatory reason, full audit trail via RowIgnorer) and immediately
  # recalculates the preview — no re-upload needed. Rejected server-side for
  # anything that isn't currently a row-level validation error (structural
  # problems and Unknown Terminal IDs are never row-ignorable).
  def ignore_row
    authorize @pos_import, :ignore_row?

    result = Finance::PosImports::RowIgnorer.call(
      @pos_import.id, row_number: params[:row_number], reason: params[:reason], actor: current_user
    )

    if result.ok?
      @pos_import.update_column(:preview_data, build_preview(@pos_import))
      redirect_to preview_import_finance_pos_import_path(@pos_import),
                  notice: t("finance.pos_imports.row_ignored", row: params[:row_number])
    else
      redirect_to preview_import_finance_pos_import_path(@pos_import), alert: result.error
    end
  end

  # POST /finance/pos_imports/:id/confirm_import
  def confirm_import
    authorize @pos_import

    result = Finance::PosImports::Importer.call(@pos_import.id, actor: current_user)

    if result.ok?
      summary = Finance::PosImports::SummaryBuilder.for_import(result.pos_import)
      redirect_to finance_pos_imports_path,
                  notice: t("finance.pos_imports.imported_summary",
                            imported:  summary[:imported_rows],
                            total:     summary[:total_rows],
                            duplicates: summary[:duplicate_rows],
                            invalid:   summary[:invalid_rows],
                            ignored:   summary[:ignored_rows],
                            expenses:  summary[:expenses_created],
                            fees:      helpers.format_currency(summary[:total_fees]))
    else
      redirect_to preview_import_finance_pos_import_path(@pos_import), alert: result.error
    end
  end

  # DELETE /finance/pos_imports/:id
  def destroy
    authorize @pos_import

    @pos_import.destroy!
    redirect_to finance_pos_imports_path, notice: t("finance.pos_imports.deleted")
  end

  private

  def set_pos_import
    @pos_import = current_user.business.pos_imports.find(params[:id])
  end

  def parse_date(value)
    Date.iso8601(value)
  rescue ArgumentError, TypeError
    Date.current
  end

  # Preserves the branch/date context the Daily Reconciliation index page
  # (the only current entry point into POS Imports) was filtered to, so the
  # back button returns to the same filtered view rather than the unfiltered
  # index.
  def daily_reconciliations_return_path
    finance_daily_reconciliations_path(
      branch_id: params[:branch_id].presence,
      from:      params[:from].presence,
      to:        params[:to].presence
    )
  end

  # Batch-resolves the DailyReconciliation each transaction's (branch,
  # calendar date) falls under, in one query for the whole page — a
  # PosTransaction has no persisted DR link (see
  # Finance::PosVerification::Comparator), but a DR's business_date is the
  # same calendar-date bucket PosTransaction.for_calendar_date matches
  # against, so branch_id + transaction_date.to_date is a reliable key.
  def daily_reconciliations_for(transactions)
    pairs = transactions.map { |t| [ t.branch_id, t.transaction_date.to_date ] }.uniq
    return {} if pairs.empty?

    branch_ids = pairs.map(&:first)
    dates      = pairs.map(&:last)

    drs = DailyReconciliation.where(branch_id: branch_ids, business_date: dates.min..dates.max).includes(:branch)
    drs.index_by { |dr| [ dr.branch_id, dr.business_date ] }.slice(*pairs)
  end

  # Runs the shared read-only Pipeline (no persistence beyond preview_data)
  # to build the preview shown before confirming. Importer re-runs the same
  # Pipeline fresh from the stored file at confirm time rather than trusting
  # this cached result.
  def build_preview(pos_import)
    pipeline = Finance::PosImports::Pipeline.call(pos_import, business: current_user.business)

    Finance::PosImports::SummaryBuilder.for_preview(
      mapped_rows: pipeline.mapped, status_split: pipeline.status_split,
      validation: pipeline.validation, resolution: pipeline.resolution, business: current_user.business,
      pos_import: pos_import
    )
  end

  # Re-derives the preview from the stored file when preview_data is absent —
  # covers direct/bookmarked access to the preview URL.
  def regenerate_preview(pos_import)
    build_preview(pos_import)
  end
end
