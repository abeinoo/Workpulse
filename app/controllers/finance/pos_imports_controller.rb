class Finance::PosImportsController < Finance::BaseController
  before_action :set_pos_import, only: %i[preview_import confirm_import ignore_row destroy]

  ACCEPTED_EXTENSION = ".xlsx".freeze

  # GET /finance/pos_imports
  def index
    authorize PosImport
    @imports = current_user.business.pos_imports
                          .includes(:imported_by)
                          .ordered
                          .limit(50)
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
