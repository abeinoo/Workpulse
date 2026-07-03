class Finance::PosImportsController < Finance::BaseController
  before_action :set_pos_import, only: %i[edit_column_mapping update_column_mapping
                                           preview_import confirm_import destroy]

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

    unless params.dig(:pos_import, :file).present?
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.file_blank"))
      return render :new, status: :unprocessable_entity
    end

    raw_bytes = params[:pos_import][:file].read
    if raw_bytes.blank?
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.file_empty"))
      return render :new, status: :unprocessable_entity
    end

    begin
      csv_data = raw_bytes.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    rescue Encoding::UndefinedConversionError, Encoding::InvalidByteSequenceError
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.unsupported_encoding"))
      return render :new, status: :unprocessable_entity
    end

    begin
      @detected_headers = Finance::PosImports::CsvParser.detect_headers(csv_data)
    rescue ArgumentError => e
      key = e.message.include?("malformed") ? "finance.pos_imports.errors.csv_malformed"
                                            : "finance.pos_imports.errors.csv_no_header"
      @pos_import.errors.add(:file, t(key))
      return render :new, status: :unprocessable_entity
    end

    if @detected_headers.empty?
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.csv_no_header"))
      return render :new, status: :unprocessable_entity
    end

    row_count = csv_row_count(csv_data)
    if row_count == 0
      @pos_import.errors.add(:file, t("finance.pos_imports.errors.no_data_rows"))
      return render :new, status: :unprocessable_entity
    end

    @pos_import.file_name = params[:pos_import][:file].original_filename

    if @pos_import.save
      @pos_import.file.attach(params[:pos_import][:file])
      redirect_to edit_column_mapping_finance_pos_import_path(@pos_import)
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /finance/pos_imports/:id/edit_column_mapping
  def edit_column_mapping
    authorize @pos_import
    # Always re-detect from the stored file — no session dependency.
    @detected_headers = Finance::PosImports::CsvParser.detect_headers(@pos_import.file.download)
  end

  # PATCH /finance/pos_imports/:id/update_column_mapping
  def update_column_mapping
    authorize @pos_import, :edit_column_mapping?

    mapping = build_column_mapping(params[:column_mapping])

    missing = Finance::PosImports::CsvParser::REQUIRED_FIELDS.select { |f| mapping[f].blank? }
    if missing.any?
      @pos_import.errors.add(:base, t("finance.pos_imports.errors.mapping_missing_required",
                                       fields: missing.join(", ")))
      @detected_headers = Finance::PosImports::CsvParser.detect_headers(@pos_import.file.download)
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    @pos_import.update!(column_mapping: mapping, status: "column_mapped")

    csv_data     = @pos_import.file.download
    parse_result = Finance::PosImports::CsvParser.parse(csv_data, column_mapping: mapping)

    if parse_result.header_error.present?
      @pos_import.errors.add(:base, parse_result.header_error)
      @detected_headers = Finance::PosImports::CsvParser.detect_headers(csv_data)
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    matcher      = Finance::PosImports::DrMatcher.new(current_user.business)
    match_result = matcher.match(parse_result.valid_rows)

    # Persist preview data on the record — never in the cookie session.
    preview = {
      "total_rows"       => parse_result.total_rows,
      "valid_count"      => parse_result.valid_count,
      "invalid_count"    => parse_result.invalid_count,
      "matched_count"    => match_result.matched_count,
      "unmatched_count"  => match_result.unmatched_count,
      "dr_count"         => match_result.affected_dr_ids.size,
      "unmatched_groups" => match_result.unmatched_groups.map { |g|
        { "branch_name" => g[:branch_name], "date" => g[:date], "count" => g[:count] }
      },
      "sample_rows" => parse_result.valid_rows.first(5).map { |r|
        r.slice("transaction_date", "branch_name", "cashier_name", "payment_method_name", "amount")
      },
      "error_rows" => parse_result.invalid_rows.first(10).map { |r|
        r.slice("row", "transaction_date", "branch_name", "cashier_name",
                "payment_method_name", "amount", "errors")
      }
    }
    @pos_import.update_column(:preview_data, preview)

    redirect_to preview_import_finance_pos_import_path(@pos_import)
  end

  # GET /finance/pos_imports/:id/preview_import
  def preview_import
    authorize @pos_import, :update_column_mapping?
    @preview = @pos_import.preview_data.presence || regenerate_preview(@pos_import)
  end

  # POST /finance/pos_imports/:id/confirm_import
  def confirm_import
    authorize @pos_import, :update_column_mapping?

    skip_unmatched = params[:skip_unmatched] == "1"

    result = Finance::PosImports::Importer.call(
      @pos_import.id,
      actor:          current_user,
      skip_unmatched: skip_unmatched
    )

    if result.ok?
      pi = result.pos_import
      redirect_to finance_daily_reconciliations_path,
                  notice: t("finance.pos_imports.imported",
                             count:    pi.matched_rows,
                             dr_count: pi.dr_count)
    else
      redirect_to preview_import_finance_pos_import_path(@pos_import),
                  alert: result.error
    end
  end

  # DELETE /finance/pos_imports/:id
  def destroy
    authorize @pos_import

    @pos_import.destroy!
    redirect_to finance_pos_imports_path,
                notice: t("finance.pos_imports.deleted")
  end

  private

  def set_pos_import
    @pos_import = current_user.business.pos_imports.find(params[:id])
  end

  def build_column_mapping(mapping_params)
    return {} unless mapping_params.respond_to?(:permit)
    permitted = mapping_params.permit(Finance::PosImports::CsvParser::ALL_FIELDS)
    permitted.to_h.reject { |_k, v| v.blank? }
  end

  def csv_row_count(csv_data)
    require "csv"
    table = CSV.parse(
      csv_data.encode("UTF-8", invalid: :replace, undef: :replace, replace: ""),
      headers: true, skip_blanks: true
    )
    table.count
  rescue CSV::MalformedCSVError
    0
  end

  # Re-builds preview from the stored file + column_mapping when preview_data is absent.
  # This covers the edge case where someone navigates directly to the preview URL
  # without going through update_column_mapping (e.g., bookmarked URL or admin action).
  def regenerate_preview(pos_import)
    csv_data     = pos_import.file.download
    parse_result = Finance::PosImports::CsvParser.parse(csv_data, column_mapping: pos_import.column_mapping)
    matcher      = Finance::PosImports::DrMatcher.new(current_user.business)
    match_result = matcher.match(parse_result.valid_rows)

    {
      "total_rows"       => parse_result.total_rows,
      "valid_count"      => parse_result.valid_count,
      "invalid_count"    => parse_result.invalid_count,
      "matched_count"    => match_result.matched_count,
      "unmatched_count"  => match_result.unmatched_count,
      "dr_count"         => match_result.affected_dr_ids.size,
      "unmatched_groups" => match_result.unmatched_groups.map { |g|
        { "branch_name" => g[:branch_name], "date" => g[:date], "count" => g[:count] }
      },
      "sample_rows" => parse_result.valid_rows.first(5).map { |r|
        r.slice("transaction_date", "branch_name", "cashier_name", "payment_method_name", "amount")
      },
      "error_rows" => parse_result.invalid_rows.first(10).map { |r|
        r.slice("row", "transaction_date", "branch_name", "cashier_name",
                "payment_method_name", "amount", "errors")
      }
    }
  end
end
