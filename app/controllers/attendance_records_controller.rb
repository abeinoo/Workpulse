class AttendanceRecordsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_record, only: [ :show, :edit, :update ]

  PER_PAGE = 50

  def index
    @can_manage = current_user.can?(:view_attendance)

    # KPI stats: unfiltered today snapshot (respects policy scope).
    # BusinessDay honours the configured start hour, so the "today" strip
    # matches the work_date that check-in/punch assigned the records to.
    biz_today = BusinessDay.current(context: current_user.business)
    @today = biz_today
    @today_stats = Attendance::DailyStats.call(
      scope: policy_scope(AttendanceRecord),
      today: biz_today
    )

    scope = policy_scope(AttendanceRecord)
              .includes(:branch, :user, shift_assignment: :shift)

    scope = apply_filters(scope) if @can_manage

    @active_filter_count = count_active_filters if @can_manage

    @total_count = scope.count
    @page        = [ (params[:page] || 1).to_i, 1 ].max

    sort_col = %w[work_date check_in_at status].include?(params[:sort]) ? params[:sort] : "work_date"
    sort_dir = params[:dir] == "asc" ? "asc" : "desc"

    @total_pages = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @page        = [ @page, @total_pages ].min

    @records = scope.order("#{sort_col} #{sort_dir}, check_in_at DESC")
                    .offset((@page - 1) * PER_PAGE)
                    .limit(PER_PAGE)

    @filter_branches = @can_manage ? visible_branches : Branch.none
    @filter_shifts   = @can_manage ? current_user.business.shifts.active.order(:name) : Shift.none
    @filter_sources  = AttendanceRecord::SOURCES
  end

  def show
    authorize @record
    @adjustments = @record.attendance_adjustments
                           .includes(:adjusted_by)
                           .order(created_at: :desc)
  end

  def new
    authorize AttendanceRecord, :create?
    @record    = AttendanceRecord.new(work_date: BusinessDay.current(context: current_user.business))
    @employees = manageable_employees
  end

  def create
    authorize AttendanceRecord, :create?

    employee = manageable_employees.find_by(id: params.dig(:attendance_record, :user_id))
    unless employee
      @record    = AttendanceRecord.new
      @employees = manageable_employees
      flash.now[:alert] = t("attendance.manual.errors.employee_required")
      return render :new, status: :unprocessable_entity
    end

    result = Attendance::ManualEntryService.call(
      employee:   employee,
      created_by: current_user,
      work_date:  params.dig(:attendance_record, :work_date),
      check_in:   params.dig(:attendance_record, :check_in_time),
      check_out:  params.dig(:attendance_record, :check_out_time),
      notes:      params.dig(:attendance_record, :notes)
    )

    if result.success?
      redirect_to attendance_record_path(result.record), notice: t("attendance.manual.flash.created")
    else
      @record    = AttendanceRecord.new(user_id: employee.id,
                                        work_date: params.dig(:attendance_record, :work_date))
      @employees = manageable_employees
      flash.now[:alert] = result.error
      render :new, status: :unprocessable_entity
    end
  end

  # ── Bulk manual entry (spreadsheet grid) ────────────────────────────────────

  def bulk
    authorize AttendanceRecord, :create?
    @employees    = manageable_employees
    @default_date = BusinessDay.current(context: current_user.business)
    @row_errors   = {}
    @rows         = []
  end

  def bulk_create
    authorize AttendanceRecord, :create?

    rows   = bulk_rows_params
    result = Attendance::BulkManualEntryService.new(
      rows:             rows,
      business:         current_user.business,
      created_by:       current_user,
      allowed_user_ids: manageable_employees.ids,
      source:           "bulk_manual"
    ).call

    if result.success?
      redirect_to attendance_records_path, notice: bulk_success_notice(result)
    else
      @employees    = manageable_employees
      @default_date = BusinessDay.current(context: current_user.business)
      @rows         = rows
      @row_errors   = result.row_errors.index_by(&:index)
      flash.now[:alert] = t("attendance.manual.bulk.validation_failed")
      render :bulk, status: :unprocessable_entity
    end
  end

  # ── CSV import (JSON preview → confirm) ─────────────────────────────────────

  def import
    authorize AttendanceRecord, :create?
  end

  def preview_import
    authorize AttendanceRecord, :create?

    file = params[:csv_file]
    unless file.present?
      return redirect_to import_attendance_records_path, alert: t("attendance.manual.import.no_file")
    end
    # Browsers report inconsistent MIME types for CSV (text/csv, application/csv,
    # application/vnd.ms-excel, application/octet-stream, even empty). Accept any
    # of those OR a .csv filename so a valid upload is never wrongly rejected.
    allowed_types = %w[text/csv text/plain application/csv application/vnd.ms-excel application/octet-stream]
    is_csv = file.content_type.to_s.in?(allowed_types) ||
             File.extname(file.original_filename.to_s).casecmp(".csv").zero?
    unless is_csv
      return redirect_to import_attendance_records_path, alert: t("attendance.manual.import.invalid_type")
    end

    @parse_result = Attendance::ManualRecordsCsvParser.new(
      csv_data:         file.read,
      business:         current_user.business,
      allowed_user_ids: manageable_employees.ids
    ).call

    unless @parse_result.headers_valid?
      return redirect_to import_attendance_records_path,
                         alert: t("attendance.manual.import.header_error", error: @parse_result.header_error)
    end

    @valid_rows_json = @parse_result.valid_rows.map do |row|
      { user_id: row.user_id, work_date: row.work_date.to_s,
        check_in: row.check_in, check_out: row.check_out, notes: row.notes }
    end.to_json
  end

  def confirm_import
    authorize AttendanceRecord, :create?

    rows = JSON.parse(params[:rows_json].to_s, symbolize_names: true)
    if rows.blank?
      return redirect_to import_attendance_records_path, alert: t("attendance.manual.import.no_data")
    end

    result = Attendance::BulkManualEntryService.new(
      rows:             rows,
      business:         current_user.business,
      created_by:       current_user,
      allowed_user_ids: manageable_employees.ids,
      source:           "csv_import"
    ).call

    if result.success?
      redirect_to attendance_records_path, notice: bulk_success_notice(result)
    else
      redirect_to import_attendance_records_path,
                  alert: t("attendance.manual.import.save_failed",
                           errors: result.row_errors.flat_map(&:messages).first(3).join("; "))
    end
  rescue JSON::ParserError
    redirect_to import_attendance_records_path, alert: t("attendance.manual.import.no_data")
  end

  def import_template
    authorize AttendanceRecord, :create?
    require "csv"
    csv_data = CSV.generate do |csv|
      csv << %w[employee_code work_date check_in check_out notes]
      csv << [ "EMP001", "2026-06-01", "09:00", "17:00", "Reconstructed from sign-in sheet" ]
      csv << [ "EMP002", "2026-06-01", "20:00", "04:00", "Overnight shift" ]
      csv << [ "EMP003", "2026-06-02", "08:30", "", "Forgot to punch out" ]
    end
    send_data csv_data, filename: "manual_attendance_template.csv",
              type: "text/csv", disposition: "attachment"
  end

  def edit
    authorize @record, :update?
  end

  def update
    authorize @record
    result = Attendance::AdjustmentService.call(
      record:      @record,
      adjusted_by: current_user,
      params:      record_params
    )

    if result.success?
      redirect_to attendance_record_path(@record), notice: t("flash.attendance_updated")
    else
      flash.now[:alert] = result.error
      render :edit, status: :unprocessable_entity
    end
  end

  private

  def set_record
    @record = policy_scope(AttendanceRecord).find(params[:id])
  end

  def apply_filters(scope)
    if params[:user_id].present?
      filter_user = resolve_filter_user(params[:user_id])
      scope = scope.where(user_id: filter_user.id) if filter_user
    elsif params[:q].present?
      q = "%#{params[:q].strip.downcase}%"
      scope = scope.joins(:user).where(
        "LOWER(users.first_name || ' ' || users.last_name) LIKE :q OR LOWER(users.employee_code) LIKE :q",
        q: q
      )
    end

    scope = scope.where(branch_id: params[:branch_id])        if params[:branch_id].present?
    scope = scope.where(status: params[:status])               if params[:status].present?
    scope = scope.where(check_in_source: params[:source])      if params[:source].present?
    scope = scope.where("work_date >= ?", params[:date_from]) if params[:date_from].present?
    scope = scope.where("work_date <= ?", params[:date_to])   if params[:date_to].present?

    if params[:shift_id].present?
      scope = scope.joins(:shift_assignment)
                   .where(shift_assignments: { shift_id: params[:shift_id] })
    end

    scope = scope.where(status: AttendanceRecord::LATE_STATUSES) if params[:late] == "1"
    scope = scope.where(check_out_at: nil)  if params[:missing_checkout] == "1"

    if params[:overnight] == "1"
      tz_name = current_user.business.timezone
      scope = scope.where.not(check_out_at: nil)
                   .where(
                     "CAST(check_out_at AT TIME ZONE 'UTC' AT TIME ZONE ? AS date) > work_date",
                     tz_name
                   )
    end

    scope
  end

  def count_active_filters
    %i[q user_id branch_id status source date_from date_to shift_id].count { |k| params[k].present? } +
      %w[late missing_checkout overnight].count { |k| params[k] == "1" }
  end

  def resolve_filter_user(user_id)
    return nil unless current_user.can?(:view_attendance)

    configured = current_user.scope_for(:view_attendance)
    if configured == "business"
      current_user.business.users.find_by(id: user_id)
    else
      # Default: use EmployeeScope which honours managed_employees + branch hierarchy.
      EmployeeScope.new(current_user).relation.find_by(id: user_id) ||
        (current_user.id == user_id.to_i ? current_user : nil)
    end
  end

  # Employees the current user may create attendance for. Honours the configured
  # data scope on manage_attendance (business_wide → all business users; otherwise
  # the managed-employee / branch hierarchy via EmployeeScope).
  # Grid rows arrive under attendance_record_rows with dynamic JS-generated keys.
  # Whitelist only the permitted fields per row (mirrors BulkAdjustments#bulk_params).
  def bulk_rows_params
    raw = params[:attendance_record_rows]
    return [] unless raw.is_a?(ActionController::Parameters) || raw.is_a?(Hash)

    raw.to_unsafe_h.values.map do |row|
      row.slice("user_id", "work_date", "check_in", "check_out", "notes").symbolize_keys
    end
  end

  def bulk_success_notice(result)
    if result.locked_count.to_i.positive?
      t("attendance.manual.bulk.created_with_locked", count: result.count, locked: result.locked_count)
    else
      t("attendance.manual.bulk.created", count: result.count)
    end
  end

  def manageable_employees
    return User.none unless current_user.can?(:manage_attendance)

    # Resolve the picker scope from the most specific permission to the most
    # general (manage → view_attendance → view_employees), so a manager granted
    # business-wide on any of them sees every employee. Used for both the picker
    # and the bulk/CSV allowed_user_ids guard so they always agree.
    EmployeeScope.new(current_user)
                 .for_permissions(:manage_attendance, :view_attendance, :view_employees)
                 .active.order(:first_name, :last_name)
  end

  def visible_branches
    return Branch.none unless current_user.can?(:view_attendance)

    configured = current_user.scope_for(:view_attendance)
    if configured == "business"
      current_user.business.branches.active.order(:name)
    else
      branch_ids = current_user.managed_branch_ids + current_user.area_managed_branch_ids
      branch_ids.any? ? Branch.where(id: branch_ids).active.order(:name) : current_user.business.branches.active.order(:name)
    end
  end

  def record_params
    params.require(:attendance_record)
          .permit(:check_in_at, :check_out_at, :reason)
          .to_h
          .symbolize_keys
  end
end
