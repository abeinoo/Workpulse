class AttendanceRecordsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_record, only: [ :show, :edit, :update ]

  PER_PAGE = 50

  def index
    scope = policy_scope(AttendanceRecord)
              .includes(:branch, :user, shift_assignment: :shift)

    manager = current_user.super_admin? || current_user.area_manager? || current_user.branch_manager?
    scope = apply_filters(scope) if manager

    @total_count  = scope.count
    @page         = [ (params[:page] || 1).to_i, 1 ].max
    @total_pages  = [ (@total_count.to_f / PER_PAGE).ceil, 1 ].max
    @page         = [ @page, @total_pages ].min

    sort_col = %w[work_date check_in_at status].include?(params[:sort]) ? params[:sort] : "work_date"
    sort_dir = params[:dir] == "asc" ? "asc" : "desc"

    @records = scope.order("#{sort_col} #{sort_dir}, check_in_at DESC")
                    .offset((@page - 1) * PER_PAGE)
                    .limit(PER_PAGE)

    @filter_branches = manager ? visible_branches : Branch.none
    @filter_shifts   = manager ? current_user.business.shifts.active.order(:name) : Shift.none
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

  def apply_filters(scope)
    # Employee filter: specific user_id or free-text search
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

    scope = scope.where(branch_id: params[:branch_id])  if params[:branch_id].present?
    scope = scope.where(status: params[:status])         if params[:status].present?
    scope = scope.where("work_date >= ?", params[:date_from]) if params[:date_from].present?
    scope = scope.where("work_date <= ?", params[:date_to])   if params[:date_to].present?

    if params[:shift_id].present?
      scope = scope.joins(:shift_assignment)
                   .where(shift_assignments: { shift_id: params[:shift_id] })
    end

    scope = scope.where(status: "late")   if params[:late] == "1"
    scope = scope.where(check_out_at: nil) if params[:missing_checkout] == "1"

    if params[:overnight] == "1"
      # Overnight: check_out_at exists on a later calendar day than the work_date
      scope = scope.where.not(check_out_at: nil)
                   .where("DATE(check_out_at) > work_date")
    end

    scope
  end

  def resolve_filter_user(user_id)
    if current_user.super_admin?
      current_user.business.users.find_by(id: user_id)
    elsif current_user.area_manager?
      area_branch_ids = Branch.where(area_manager_id: current_user.id).pluck(:id)
      User.joins(:user_branches)
          .where(user_branches: { branch_id: area_branch_ids })
          .find_by(id: user_id)
    elsif current_user.branch_manager?
      current_user.managed_employees.find_by(id: user_id)
    end
  end

  def visible_branches
    if current_user.super_admin? || current_user.accountant?
      current_user.business.branches.active.order(:name)
    elsif current_user.area_manager?
      Branch.where(area_manager_id: current_user.id).active.order(:name)
    elsif current_user.branch_manager?
      current_user.branches.active.order(:name)
    else
      Branch.none
    end
  end

  def record_params
    params.require(:attendance_record)
          .permit(:check_in_at, :check_out_at, :status, :reason)
          .to_h
          .symbolize_keys
  end
end
