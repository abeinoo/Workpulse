class Admin::BranchesController < Admin::BaseController
  def index
    authorize Branch
    @branches = policy_scope(Branch).order(:name)
  end

  def show
    @branch = find_branch
    authorize @branch
    today = Date.current

    # Branch membership is shift-driven: employees currently assigned to this branch
    # via an active ShiftAssignment.
    @employees = User.where(id: ShiftAssignment.user_ids_for_branches([ @branch.id ]), active: true)
                     .includes(:permission_role, profile_photo_attachment: :blob)
                     .order(:first_name, :last_name)
    @branch_manager = @branch.branch_manager

    @today_records = @branch.attendance_records
                             .for_date(today)
                             .includes({ user: { profile_photo_attachment: :blob } }, shift_assignment: :shift)
    @today_records_by_user = @today_records.index_by(&:user_id)

    today_arr = @today_records_by_user.values
    @attendance_stats = {
      total:            @employees.count,
      checked_in:       today_arr.count { |r| r.check_in_at.present? },
      missing_checkout: today_arr.count { |r| r.check_in_at.present? && r.check_out_at.nil? },
      late:             today_arr.count(&:late?),
      early_leave:      today_arr.count(&:early_leave?)
    }

    @shift_assignments = @branch.shift_assignments.current
                                 .includes({ user: { profile_photo_attachment: :blob } }, shift: :penalty_rules)
                                 .order(:id)

    @payroll_period = @branch.payroll_periods
                              .where(period_month: today.month, period_year: today.year)
                              .includes(payroll_entries: { user: { profile_photo_attachment: :blob } })
                              .first

    branch_user_ids = ShiftAssignment.user_ids_for_branches([ @branch.id ])

    @pending_requests = EmployeeRequest
                          .where(user_id: branch_user_ids, status: :pending)
                          .includes(user: { profile_photo_attachment: :blob })
                          .order(created_at: :desc)
                          .limit(10)

    @recent_requests = EmployeeRequest
                         .where(user_id: branch_user_ids, status: [ :approved, :rejected ])
                         .includes({ user: { profile_photo_attachment: :blob } }, :reviewed_by)
                         .order(updated_at: :desc)
                         .limit(10)
  end

  def new
    @branch = current_user.business.branches.build
    authorize @branch
    load_managers
  end

  def create
    @branch = current_user.business.branches.build(branch_params)
    authorize @branch
    if @branch.save
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_created")
    else
      load_managers
      render :new, status: :unprocessable_entity
    end
  end

  def edit
    @branch = find_branch
    authorize @branch
    load_managers
  end

  def update
    @branch = find_branch
    authorize @branch
    if @branch.update(branch_params)
      redirect_to admin_branch_path(@branch), notice: t("flash.branch_updated")
    else
      load_managers
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @branch = find_branch
    authorize @branch
    @branch.destroy
    redirect_to admin_branches_path, notice: t("flash.branch_removed")
  end

  private

  def find_branch
    current_user.business.branches.find(params[:id])
  end

  def load_managers
    all_active = current_user.business.users.active.order(:first_name, :last_name)
    @managers      = all_active
    @area_managers = all_active
  end

  def branch_params
    params.require(:branch).permit(
      :name, :address, :phone_number, :active,
      :branch_manager_id, :area_manager_id,
      :geolocation_enabled, :latitude, :longitude, :radius_meters
    )
  end
end
