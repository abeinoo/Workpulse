class Admin::AttendanceRecordsController < Admin::BaseController
  # Records resolve through policy_scope(AttendanceRecord) and AttendanceRecordPolicy
  # — the same rules as AttendanceRecordsController — so the business, the
  # view_attendance data scope and manage_attendance all apply here too (SEC-M2-2).
  def index
    authorize AttendanceRecord
    scope = policy_scope(AttendanceRecord)
              .includes(:user, :branch)
              .order(date: :desc, created_at: :desc)

    scope = scope.where(date: params[:date]) if params[:date].present?
    scope = scope.where(branch_id: params[:branch_id]) if params[:branch_id].present?

    @records  = scope.limit(100)
    @branches = current_user.business.branches.active.order(:name)
  end

  def show
    @record = find_record
    authorize @record
  end

  def update
    @record = find_record
    authorize @record
    result = Attendance::AdjustmentService.call(
      record:      @record,
      adjusted_by: current_user,
      params:      record_params
    )

    if result.success?
      redirect_to admin_attendance_record_path(@record), notice: t("flash.attendance_updated")
    else
      flash.now[:alert] = result.error
      render :show, status: :unprocessable_entity
    end
  end

  private

  def find_record
    policy_scope(AttendanceRecord).find(params[:id])
  end

  def record_params
    params.require(:attendance_record).permit(:check_in_at, :check_out_at, :reason)
  end
end
