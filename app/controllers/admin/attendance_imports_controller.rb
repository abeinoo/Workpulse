require "csv"

class Admin::AttendanceImportsController < Admin::BaseController
  before_action :set_import, only: [ :show, :confirm, :cancel, :failed_rows ]

  def new
    authorize AttendanceImportLog
    @recent_imports = AttendanceImportLog
                        .where(business_id: current_user.business_id)
                        .order(created_at: :desc)
                        .limit(10)
                        .includes(:imported_by)
  end

  def create
    authorize AttendanceImportLog

    unless params[:file].present?
      redirect_to new_admin_attendance_import_path,
                  alert: t("attendance_imports.errors.no_file") and return
    end

    unless params[:file].content_type.in?([ "text/csv", "text/plain", "application/octet-stream", "application/vnd.ms-excel" ])
      redirect_to new_admin_attendance_import_path,
                  alert: t("attendance_imports.errors.invalid_type") and return
    end

    result = Attendance::CsvImporter.parse(
      params[:file].read,
      business: current_user.business
    )

    unless result.headers_valid?
      redirect_to new_admin_attendance_import_path,
                  alert: t("attendance_imports.errors.invalid_headers", error: result.header_error) and return
    end

    import = AttendanceImportLog.create!(
      business_id:      current_user.business_id,
      imported_by:      current_user,
      filename:         params[:file].original_filename,
      status:           "pending",
      total_rows:       result.total_rows,
      imported_rows:    0,
      failed_rows_count: result.rows.count { |r| !r["valid"] },
      metadata:         { "preview" => result.rows }
    )

    redirect_to admin_attendance_import_path(import)
  end

  def show
    authorize @import
  end

  def confirm
    authorize @import

    unless @import.pending?
      redirect_to admin_attendance_import_path(@import) and return
    end

    Attendance::CsvImporter.execute(@import)
    redirect_to admin_attendance_import_path(@import),
                notice: t("attendance_imports.flash.confirmed",
                          count: @import.reload.imported_rows)
  end

  # Discards a staged (pending) import without creating any attendance records.
  # The preview was persisted on upload; cancelling deletes that staged log so
  # nothing can be confirmed later. Completed/failed imports are immutable.
  def cancel
    authorize @import

    unless @import.pending?
      redirect_to admin_attendance_import_path(@import),
                  alert: t("attendance_imports.flash.cannot_cancel") and return
    end

    @import.destroy!
    redirect_to new_admin_attendance_import_path,
                notice: t("attendance_imports.flash.cancelled")
  end

  def failed_rows
    authorize @import

    all_invalid = @import.invalid_preview_rows + @import.failed_import_rows
    csv_data = CSV.generate(headers: true) do |csv|
      csv << [ "row", "employee_code", "time", "work_date", "errors" ]
      all_invalid.each do |row|
        errs      = (row["errors"].presence || [ row["error"] ]).compact.join("; ")
        time_field = row["time"].presence || row["check_in_at"]
        csv << [ row["row"], row["employee_code"], time_field, row["work_date"], errs ]
      end
    end

    send_data csv_data,
              filename:    "import_errors_#{@import.id}.csv",
              type:        "text/csv",
              disposition: "attachment"
  end

  def template
    authorize AttendanceImportLog, :template?

    csv_data = CSV.generate(headers: true) do |csv|
      csv << [ "employee_code", "time" ]
      csv << [ "EMP001", "2025-01-15 09:00:00" ]
      csv << [ "EMP001", "2025-01-15 17:00:00" ]
      csv << [ "EMP002", "2025-01-15 08:30:00" ]
      csv << [ "EMP002", "2025-01-15 16:30:00" ]
      csv << [ "EMP003", "2025-01-15 07:45:00" ]
    end

    send_data csv_data,
              filename:    "attendance_import_template.csv",
              type:        "text/csv",
              disposition: "attachment"
  end

  private

  def set_import
    @import = AttendanceImportLog
                .where(business_id: current_user.business_id)
                .find(params[:id])
  end
end
