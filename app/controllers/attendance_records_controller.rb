class AttendanceRecordsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_record, only: [ :show, :edit, :update ]

  def index
    scope = policy_scope(AttendanceRecord).includes(:branch, :user)

    if params[:user_id].present?
      # Managers can filter to a specific managed employee's history
      @filter_user = resolve_filter_user(params[:user_id])
      scope = scope.where(user_id: @filter_user.id) if @filter_user
    end

    @records = scope.order(date: :desc).limit(100)
  end

  def show
    authorize @record
    @adjustments = @record.attendance_adjustments
                           .includes(:adjusted_by)
                           .order(created_at: :desc)
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

  def resolve_filter_user(user_id)
    if current_user.super_admin?
      current_user.business.users.find_by(id: user_id)
    elsif current_user.branch_manager?
      current_user.managed_employees.find_by(id: user_id)
    else
      nil
    end
  end

  def record_params
    params.require(:attendance_record)
          .permit(:check_in_at, :check_out_at, :status, :reason)
          .to_h
          .symbolize_keys
  end
end
