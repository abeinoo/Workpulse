class Finance::SalesImportsController < Finance::BaseController
  before_action :set_sales_import, only: %i[show edit_column_mapping update_column_mapping
                                           preview_import confirm_import destroy]

  DEFAULT_PER_PAGE = 25

  SORT_COLUMNS = { "date" => "transaction_date", "amount" => "amount", "fee" => "fees" }.freeze

  COLUMN_DETECTION_RULES = [
    [ "transaction_date",    %w[payment\ date transaction\ date date] ],
    [ "branch_name",         %w[location branch store outlet] ],
    [ "cashier_name",        %w[team\ member cashier employee staff operator member] ],
    [ "payment_method_name", %w[payment\ method method] ],
    [ "amount",              %w[payment\ amount amount total] ],
    [ "reference_number",    %w[payment\ no reference receipt ref voucher] ],
    [ "transaction_id",      %w[transaction\ id trans\ id] ],
    [ "sale_number",         %w[sale\ no sale\ number sale\ id] ],
    [ "transaction_type",    %w[type transaction\ type sale\ type payment\ type kind] ]
  ].freeze

  # GET /finance/sales_imports
  def index
    authorize SalesImport

    base_scope = current_user.business.sales_imports

    @imports = base_scope
                 .then { |s| params[:file_name].present? ? s.where("file_name ILIKE ?", "%#{params[:file_name]}%") : s }
                 .then { |s| params[:status].present? ? s.where(status: params[:status]) : s }
                 .then { |s| params[:imported_by_id].present? ? s.where(imported_by_id: params[:imported_by_id]) : s }
                 .then { |s| params[:branch_name].present? ? s.where(id: sales_transaction_import_ids(params[:branch_name])) : s }
                 .then { |s| params[:date_from].present? ? s.where(created_at: parse_date(params[:date_from]).beginning_of_day..) : s }
                 .then { |s| params[:date_to].present? ? s.where(created_at: ..parse_date(params[:date_to]).end_of_day) : s }
                 .includes(:imported_by)
                 .ordered

    @page        = [ params.fetch(:page, 1).to_i, 1 ].max
    @total_count = @imports.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @imports     = @imports.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE).to_a

    @import_branch_names = branch_names_by_import(@imports)

    @filter_uploaders    = current_user.business.users.where(id: base_scope.distinct.pluck(:imported_by_id)).sort_by(&:full_name)
    @filter_branch_names = SalesTransaction.where(business_id: current_user.business.id).distinct.pluck(:branch_name).compact.sort
    @filter_statuses     = SalesImport::STATUSES

    # Summary cards reflect the business-wide picture (base_scope, before
    # filters) — see Performance Guidelines: "Scope counts separately from
    # the display set."
    @summary = {
      total_imports:  base_scope.count,
      total_rows:     base_scope.sum(:total_rows),
      imported_rows:  base_scope.sum(:matched_rows),
      duplicate_rows: base_scope.sum(:duplicate_rows),
      failed_rows:    base_scope.sum(:failed_rows)
    }
  end

  # GET /finance/sales_imports/:id
  def show
    authorize @sales_import

    @transactions = @sales_import.sales_transactions
                       .then { |s| params[:transaction_id].present? ? s.where("transaction_id ILIKE ?", "%#{params[:transaction_id]}%") : s }
                       .then { |s| params[:reference_number].present? ? s.where("reference_number ILIKE ?", "%#{params[:reference_number]}%") : s }
                       .then { |s| params[:branch_name].present? ? s.where(branch_name: params[:branch_name]) : s }
                       .then { |s| params[:payment_method].present? ? s.where(payment_method_name: params[:payment_method]) : s }
                       .then { |s| params[:status].present? ? s.where(status: params[:status]) : s }
                       .then { |s| params[:date_from].present? ? s.where(transaction_date: parse_date(params[:date_from])..) : s }
                       .then { |s| params[:date_to].present? ? s.where(transaction_date: ..parse_date(params[:date_to])) : s }
                       .includes(daily_reconciliation: :branch)
                       .order(Arel.sql("#{SORT_COLUMNS.fetch(params[:sort], "transaction_date")} #{params[:direction] == "asc" ? "asc" : "desc"}"))

    @page        = [ params.fetch(:page, 1).to_i, 1 ].max
    @total_count = @transactions.count
    @total_pages = [ (@total_count.to_f / DEFAULT_PER_PAGE).ceil, 1 ].max
    @transactions = @transactions.offset((@page - 1) * DEFAULT_PER_PAGE).limit(DEFAULT_PER_PAGE).to_a

    @filter_branch_names    = @sales_import.sales_transactions.distinct.pluck(:branch_name).compact.sort
    @filter_payment_methods = @sales_import.sales_transactions.distinct.pluck(:payment_method_name).compact.sort
    @filter_statuses        = @sales_import.sales_transactions.distinct.pluck(:status).compact.sort
  end

  # GET /finance/sales_imports/new
  def new
    @sales_import = SalesImport.new
    authorize @sales_import
  end

  # POST /finance/sales_imports
  def create
    @sales_import = current_user.business.sales_imports.build
    @sales_import.imported_by = current_user
    authorize @sales_import

    unless params.dig(:sales_import, :file).present?
      @sales_import.errors.add(:file, t("finance.sales_imports.errors.file_blank"))
      return render :new, status: :unprocessable_entity
    end

    raw_bytes = params[:sales_import][:file].read
    if raw_bytes.blank?
      @sales_import.errors.add(:file, t("finance.sales_imports.errors.file_empty"))
      return render :new, status: :unprocessable_entity
    end

    csv_data = Finance::SalesImports::CsvParser.to_utf8(raw_bytes)

    begin
      @detected_headers = Finance::SalesImports::CsvParser.detect_headers(csv_data)
    rescue ArgumentError => e
      key = e.message.include?("malformed") ? "finance.sales_imports.errors.csv_malformed"
                                            : "finance.sales_imports.errors.csv_no_header"
      @sales_import.errors.add(:file, t(key))
      return render :new, status: :unprocessable_entity
    end

    if @detected_headers.empty?
      @sales_import.errors.add(:file, t("finance.sales_imports.errors.csv_no_header"))
      return render :new, status: :unprocessable_entity
    end

    row_count = csv_row_count(csv_data)
    if row_count == 0
      @sales_import.errors.add(:file, t("finance.sales_imports.errors.no_data_rows"))
      return render :new, status: :unprocessable_entity
    end

    @sales_import.file_name = params[:sales_import][:file].original_filename

    if @sales_import.save
      @sales_import.file.attach(params[:sales_import][:file])
      redirect_to edit_column_mapping_finance_sales_import_path(@sales_import)
    else
      render :new, status: :unprocessable_entity
    end
  end

  # GET /finance/sales_imports/:id/edit_column_mapping
  def edit_column_mapping
    authorize @sales_import
    # Always re-detect from the stored file — no session dependency.
    @detected_headers = Finance::SalesImports::CsvParser.detect_headers(@sales_import.file.download)
    # Pre-fill an auto-detected mapping on first visit (when no mapping has been saved yet).
    if @sales_import.column_mapping.blank?
      @sales_import.column_mapping = auto_detect_column_mapping(@detected_headers)
    end
  end

  # PATCH /finance/sales_imports/:id/update_column_mapping
  def update_column_mapping
    authorize @sales_import, :edit_column_mapping?

    mapping = build_column_mapping(params[:column_mapping])

    missing = Finance::SalesImports::CsvParser::REQUIRED_FIELDS.select { |f| mapping[f].blank? }
    if missing.any?
      @sales_import.errors.add(:base, t("finance.sales_imports.errors.mapping_missing_required",
                                       fields: missing.join(", ")))
      @detected_headers = Finance::SalesImports::CsvParser.detect_headers(@sales_import.file.download)
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    @sales_import.update!(column_mapping: mapping, status: "column_mapped")

    csv_data     = @sales_import.file.download
    parse_result = Finance::SalesImports::CsvParser.parse(csv_data, column_mapping: mapping)

    if parse_result.header_error.present?
      @sales_import.errors.add(:base, parse_result.header_error)
      @detected_headers = Finance::SalesImports::CsvParser.detect_headers(csv_data)
      return render :edit_column_mapping, status: :unprocessable_entity
    end

    matcher      = Finance::SalesImports::DrMatcher.new(current_user.business)
    match_result = matcher.match(parse_result.valid_rows)

    incoming_refs  = parse_result.valid_rows.filter_map { |r| r["reference_number"].presence }.uniq
    existing_refs  = incoming_refs.any? ?
      SalesTransaction
        .where(business_id: current_user.business_id,
               reference_number: incoming_refs)
        .where.not(sales_import_id: @sales_import.id)
        .pluck(:reference_number)
        .to_set :
      Set.new
    duplicate_count = parse_result.valid_rows.count { |row|
      ref = row["reference_number"]
      ref.present? && existing_refs.include?(ref)
    }

    # Persist preview data on the record — never in the cookie session.
    preview = {
      "total_rows"       => parse_result.total_rows,
      "valid_count"      => parse_result.valid_count,
      "invalid_count"    => parse_result.invalid_count,
      "duplicate_count"  => duplicate_count,
      "matched_count"    => match_result.matched_count,
      "unmatched_count"  => match_result.unmatched_count,
      "dr_count"         => match_result.affected_dr_ids.size,
      "unmatched_groups" => match_result.unmatched_groups.map { |g|
        {
          "branch_name"         => g[:branch_name],
          "cashier_name"        => g[:cashier_name],
          "payment_method_name" => g[:payment_method_name],
          "date"                => g[:date],
          "count"               => g[:count],
          "reason"              => g[:reason].to_s
        }
      },
      "sample_rows" => parse_result.valid_rows.first(5).map { |r|
        r.slice("transaction_date", "branch_name", "cashier_name", "payment_method_name", "amount")
      },
      "error_rows" => parse_result.invalid_rows.first(10).map { |r|
        r.slice("row", "transaction_date", "branch_name", "cashier_name",
                "payment_method_name", "amount", "errors")
      }
    }
    @sales_import.update_column(:preview_data, preview)

    redirect_to preview_import_finance_sales_import_path(@sales_import)
  end

  # GET /finance/sales_imports/:id/preview_import
  def preview_import
    authorize @sales_import, :update_column_mapping?
    @preview = @sales_import.preview_data.presence || regenerate_preview(@sales_import)
  end

  # POST /finance/sales_imports/:id/confirm_import
  def confirm_import
    authorize @sales_import, :update_column_mapping?

    skip_unmatched = params[:skip_unmatched] == "1"

    result = Finance::SalesImports::Importer.call(
      @sales_import.id,
      actor:          current_user,
      skip_unmatched: skip_unmatched
    )

    if result.ok?
      pi = result.sales_import
      redirect_to finance_daily_reconciliations_path,
                  notice: t("finance.sales_imports.imported_summary",
                             total:      pi.total_rows,
                             imported:   pi.matched_rows,
                             duplicates: pi.duplicate_rows,
                             invalid:    pi.failed_rows)
    else
      redirect_to preview_import_finance_sales_import_path(@sales_import),
                  alert: result.error
    end
  end

  # DELETE /finance/sales_imports/:id
  def destroy
    authorize @sales_import

    @sales_import.destroy!
    redirect_to finance_sales_imports_path,
                notice: t("finance.sales_imports.deleted")
  end

  private

  def set_sales_import
    @sales_import = current_user.business.sales_imports.find(params[:id])
  end

  def parse_date(value)
    Date.iso8601(value)
  rescue ArgumentError, TypeError
    Date.current
  end

  def sales_transaction_import_ids(branch_name)
    SalesTransaction.where(business_id: current_user.business.id, branch_name: branch_name).select(:sales_import_id)
  end

  # Batch-resolves the distinct branch names present in each import's
  # transactions in one query for the whole page, rather than one query per
  # row — SalesTransaction only carries a free-text branch_name (populated
  # from the CSV), not a real Branch association, so this can't be an
  # `.includes(:branch)` preload.
  def branch_names_by_import(imports)
    return {} if imports.empty?

    SalesTransaction.where(sales_import_id: imports.map(&:id))
                     .distinct
                     .pluck(:sales_import_id, :branch_name)
                     .group_by(&:first)
                     .transform_values { |pairs| pairs.filter_map(&:last).sort }
  end

  def auto_detect_column_mapping(headers)
    norm = ->(s) { s.to_s.downcase.gsub(/[\s\-_]+/, " ").strip }
    used = Set.new

    COLUMN_DETECTION_RULES.each_with_object({}) do |(field, keywords), mapping|
      matched = keywords.lazy.filter_map { |kw|
        headers.find { |h| !used.include?(h) && norm.call(h).include?(kw) }
      }.first
      next unless matched

      mapping[field] = matched
      used << matched
    end
  end

  def build_column_mapping(mapping_params)
    return {} unless mapping_params.respond_to?(:permit)
    permitted = mapping_params.permit(Finance::SalesImports::CsvParser::ALL_FIELDS)
    permitted.to_h.reject { |_k, v| v.blank? }
  end

  def csv_row_count(csv_data)
    require "csv"
    table = CSV.parse(
      Finance::SalesImports::CsvParser.to_utf8(csv_data),
      headers: true, skip_blanks: true
    )
    table.count
  rescue CSV::MalformedCSVError
    0
  end

  # Re-builds preview from the stored file + column_mapping when preview_data is absent.
  # This covers the edge case where someone navigates directly to the preview URL
  # without going through update_column_mapping (e.g., bookmarked URL or admin action).
  def regenerate_preview(sales_import)
    csv_data     = sales_import.file.download
    parse_result = Finance::SalesImports::CsvParser.parse(csv_data, column_mapping: sales_import.column_mapping)
    matcher      = Finance::SalesImports::DrMatcher.new(current_user.business)
    match_result = matcher.match(parse_result.valid_rows)

    incoming_refs  = parse_result.valid_rows.filter_map { |r| r["reference_number"].presence }.uniq
    existing_refs  = incoming_refs.any? ?
      SalesTransaction
        .where(business_id: current_user.business_id,
               reference_number: incoming_refs)
        .where.not(sales_import_id: sales_import.id)
        .pluck(:reference_number)
        .to_set :
      Set.new
    duplicate_count = parse_result.valid_rows.count { |row|
      ref = row["reference_number"]
      ref.present? && existing_refs.include?(ref)
    }

    {
      "total_rows"       => parse_result.total_rows,
      "valid_count"      => parse_result.valid_count,
      "invalid_count"    => parse_result.invalid_count,
      "duplicate_count"  => duplicate_count,
      "matched_count"    => match_result.matched_count,
      "unmatched_count"  => match_result.unmatched_count,
      "dr_count"         => match_result.affected_dr_ids.size,
      "unmatched_groups" => match_result.unmatched_groups.map { |g|
        {
          "branch_name"         => g[:branch_name],
          "cashier_name"        => g[:cashier_name],
          "payment_method_name" => g[:payment_method_name],
          "date"                => g[:date],
          "count"               => g[:count],
          "reason"              => g[:reason].to_s
        }
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
