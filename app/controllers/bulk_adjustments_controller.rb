class BulkAdjustmentsController < ApplicationController
  before_action :authenticate_user!
  before_action :authorize_bulk!

  CSV_TEMPLATE_HEADERS = %w[employee_code adjustment_type amount reason period_month period_year].freeze
  CSV_TEMPLATE_EXAMPLE = [
    %w[EMP001 cash_incentive 500.00 Q2\ Performance\ Bonus 5 2026],
    %w[EMP002 commission     750.00 April\ Sales\ Commission 5 2026],
    %w[EMP003 manual_deduction 100.00 Equipment\ Damage 5 2026]
  ].freeze

  # GET /bulk_adjustments/new
  def new
    @employees     = manageable_employees
    @branches      = branches_for_user
    load_selectable_periods
    @default_type  = params[:adjustment_type].presence || "cash_incentive"
    @row_errors    = {}
  end

  # POST /bulk_adjustments/new
  def create
    bp = bulk_params
    period_year, period_month = parse_period_key(bp[:period_key])

    if period_month.nil?
      reload_new_form(bp)
      flash.now[:alert] = t("adjustments.new.no_periods")
      return render :new, status: :unprocessable_entity
    end

    # Inject the shared period into each row (the period select is at form level)
    rows = (bp[:rows] || {}).values
             .reject { |r| r["user_id"].blank? && r["amount"].blank? }
             .map { |r| r.merge("period_month" => period_month, "period_year" => period_year) }

    result = Adjustments::BulkCreateService.new(
      rows:             rows,
      business:         current_user.business,
      created_by:       current_user,
      allowed_user_ids: manageable_employees.ids,
      import_source:    "manual"
    ).call

    if result.success?
      redirect_to adjustments_path(period_month: period_month, period_year: period_year),
                  notice: t("bulk_adjustments.created", count: result.count)
    else
      reload_new_form(bp)
      @row_errors       = result.row_errors.index_by(&:index)
      flash.now[:alert] = t("bulk_adjustments.validation_failed")
      render :new, status: :unprocessable_entity
    end
  end

  # GET /bulk_adjustments/import
  def import
    load_selectable_periods
  end

  # POST /bulk_adjustments/import/preview
  def preview_import
    file = params[:csv_file]

    unless file.present?
      redirect_to import_bulk_adjustments_path, alert: t("bulk_adjustments.import.no_file")
      return
    end

    unless file.content_type.in?(%w[text/csv text/plain application/csv application/vnd.ms-excel])
      redirect_to import_bulk_adjustments_path, alert: t("bulk_adjustments.import.invalid_type")
      return
    end

    load_selectable_periods
    @default_year, @default_month = parse_period_key(params[:period_key])
    @default_month ||= Date.current.month
    @default_year  ||= Date.current.year

    result = Adjustments::BulkCsvParser.new(
      csv_data:      file.read,
      business:      current_user.business,
      default_month: @default_month,
      default_year:  @default_year
    ).call

    if !result.headers_valid?
      redirect_to import_bulk_adjustments_path,
                  alert: t("bulk_adjustments.import.header_error", error: result.header_error)
      return
    end

    @parse_result  = result
    # Encode valid rows as JSON for the confirm form (avoids server-side session storage)
    @valid_rows_json = result.valid_rows.map do |row|
      {
        user_id:         row.user,
        adjustment_type: row.adjustment_type,
        amount:          row.amount,
        reason:          row.reason,
        period_month:    row.period_month,
        period_year:     row.period_year
      }
    end.to_json
  end

  # POST /bulk_adjustments/import/confirm
  def confirm_import
    rows_json = params[:rows_json].presence
    unless rows_json
      redirect_to import_bulk_adjustments_path, alert: t("bulk_adjustments.import.no_data")
      return
    end

    rows = JSON.parse(rows_json, symbolize_names: true)
    period_month = params[:period_month]&.to_i.presence || Date.current.month
    period_year  = params[:period_year]&.to_i.presence  || Date.current.year

    result = Adjustments::BulkCreateService.new(
      rows:             rows,
      business:         current_user.business,
      created_by:       current_user,
      allowed_user_ids: manageable_employees.ids,
      import_source:    "csv_import"
    ).call

    if result.success?
      redirect_to adjustments_path(period_month: period_month, period_year: period_year),
                  notice: t("bulk_adjustments.import.confirmed", count: result.count)
    else
      redirect_to import_bulk_adjustments_path,
                  alert: t("bulk_adjustments.import.save_failed",
                           errors: result.row_errors.map(&:messages).flatten.first(3).join("; "))
    end
  rescue JSON::ParserError
    redirect_to import_bulk_adjustments_path, alert: t("bulk_adjustments.import.no_data")
  end

  # GET /bulk_adjustments/import/template
  def template
    csv_data = CSV.generate(force_quotes: false) do |csv|
      csv << CSV_TEMPLATE_HEADERS
      CSV_TEMPLATE_EXAMPLE.each { |row| csv << row }
    end

    send_data csv_data,
              filename:     "bulk_adjustments_template.csv",
              type:         "text/csv; charset=utf-8",
              disposition:  "attachment"
  end

  private

  def authorize_bulk!
    authorize PayrollAdjustment.new(business: current_user.business), :new?
  rescue Pundit::NotAuthorizedError
    redirect_to adjustments_path, alert: t("flash.not_authorized")
  end

  def manageable_employees
    # Resolve scope most-specific-first (manage_adjustments → view_payroll →
    # view_employees) so a business-wide manager sees every employee. Falls back
    # to the managed hierarchy when none is configured.
    EmployeeScope.new(current_user)
                 .for_permissions(:manage_adjustments, :view_payroll, :view_employees)
                 .active
                 .order(:first_name, :last_name)
  end

  def branches_for_user
    Branch.for_business(current_user.business).active.order(:name)
  end

  # Open payroll periods an adjustment may target (current month + upcoming, minus
  # any period already processed). Shared by the manual and CSV-import forms.
  def load_selectable_periods
    @selectable_periods  = Adjustments::SelectablePeriods.new(current_user.business).options
    @selected_period_key = params[:period_key].presence || @selectable_periods.first&.last
  end

  def reload_new_form(bp)
    @employees           = manageable_employees
    @branches            = branches_for_user
    @default_type        = "cash_incentive"
    @selectable_periods  = Adjustments::SelectablePeriods.new(current_user.business).options
    @selected_period_key = bp[:period_key].presence || @selectable_periods.first&.last
  end

  # Splits a "YYYY-M" period key into [year, month]; returns [nil, nil] when absent
  # or malformed so callers can require an explicit selection (no silent default).
  def parse_period_key(key)
    return [ nil, nil ] unless key.to_s =~ /\A(\d{4})-(\d{1,2})\z/

    [ Regexp.last_match(1).to_i, Regexp.last_match(2).to_i ]
  end

  def bulk_params
    safe = params.require(:bulk_adjustment).permit(:period_key)

    # rows has dynamic timestamp-based keys set by the Stimulus controller.
    # We extract them via to_unsafe_h and whitelist only the permitted fields.
    raw_rows = params.dig(:bulk_adjustment, :rows)
    if raw_rows.is_a?(ActionController::Parameters) || raw_rows.is_a?(Hash)
      safe[:rows] = raw_rows.to_unsafe_h.transform_values do |row|
        row.slice("user_id", "adjustment_type", "amount", "reason")
      end
    else
      safe[:rows] = {}
    end

    safe
  end
end
